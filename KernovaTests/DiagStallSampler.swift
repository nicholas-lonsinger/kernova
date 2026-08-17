// DIAGNOSTIC — scratch branch only. Never merged.
//
// Samples, from a dedicated Mach thread (immune to cooperative-pool and main-
// queue starvation), the four quantities that separate the candidate causes of
// a heartbeat cadence gap in this test host:
//
//   mainQ  — age of an outstanding `DispatchQueue.main.async` probe. High when
//            the MainActor's executor is not draining: either the main thread
//            is blocked, or it is inside a nested event loop entered from a
//            main-queue callout (which cannot drain the queue).
//   runLoop— age of an outstanding `CFRunLoopPerformBlock` probe on the main
//            run loop. A nested event loop DOES run these, so
//            (runLoop fast, mainQ slow) means "main thread is inside a nested
//            wait", while (both slow) means "main thread is truly blocked or
//            the process has no CPU".
//   pool   — age of an outstanding `Task.detached` probe: cooperative-pool
//            scheduling latency.
//   tick   — this sampler thread's own overrun past its 100 ms period: the
//            floor of whole-process CPU starvation.
//
// Plus CPU accounting: this task's CPU seconds burned per tick, and the
// system-wide busy/idle tick deltas, so "we are burning the box" separates
// from "another process is".

import Darwin
import Foundation

// MARK: - Mach readings

private func systemCPUTicks() -> (busy: Double, idle: Double) {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
            host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, raw, &count)
        }
    }
    guard result == KERN_SUCCESS else { return (0, 0) }
    let user = Double(info.cpu_ticks.0)
    let system = Double(info.cpu_ticks.1)
    let idle = Double(info.cpu_ticks.2)
    let nice = Double(info.cpu_ticks.3)
    return (user + system + nice, idle)
}

private func processCPUSeconds() -> Double {
    var total = 0.0
    var times = task_thread_times_info()
    var timesCount = mach_msg_type_number_t(
        MemoryLayout<task_thread_times_info_data_t>.size / MemoryLayout<natural_t>.size)
    let timesResult = withUnsafeMutablePointer(to: &times) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(timesCount)) { raw in
            task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), raw, &timesCount)
        }
    }
    if timesResult == KERN_SUCCESS {
        total += Double(times.user_time.seconds) + Double(times.user_time.microseconds) / 1e6
        total += Double(times.system_time.seconds) + Double(times.system_time.microseconds) / 1e6
    }
    var basic = mach_task_basic_info()
    var basicCount = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
    let basicResult = withUnsafeMutablePointer(to: &basic) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) { raw in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), raw, &basicCount)
        }
    }
    if basicResult == KERN_SUCCESS {
        total += Double(basic.user_time.seconds) + Double(basic.user_time.microseconds) / 1e6
        total += Double(basic.system_time.seconds) + Double(basic.system_time.microseconds) / 1e6
    }
    return total
}

private func liveThreadCount() -> Int {
    var list: thread_act_array_t?
    var count: mach_msg_type_number_t = 0
    guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return -1 }
    let n = Int(count)
    for index in 0..<n { mach_port_deallocate(mach_task_self_, list[index]) }
    vm_deallocate(
        mach_task_self_, vm_address_t(UInt(bitPattern: list)),
        vm_size_t(n * MemoryLayout<thread_t>.size))
    return n
}

private func nowSeconds() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
}

// MARK: - DiagStallSampler

/// Samples scheduling latency and CPU attribution every 100 ms from a dedicated
/// thread. Diagnostic only.
final class DiagStallSampler: @unchecked Sendable {
    private struct Sample {
        var t: Double
        var mainQ: Double
        var runLoop: Double
        var pool: Double
        var tick: Double
        var procCPU: Double
        var sysBusy: Double
        var sysIdle: Double
        var threads: Int
    }

    private let lock = NSLock()
    private var samples: [Sample] = []
    private var marks: [(Double, String)] = []
    private var running = true
    private var startTime = 0.0

    private var mainQArmed: Double?
    private var runLoopArmed: Double?
    private var poolArmed: Double?

    private let period = 0.1

    func start() {
        startTime = nowSeconds()
        let thread = Thread { [weak self] in self?.loop() }
        thread.name = "DiagStallSampler"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() { lock.withLock { running = false } }

    /// Records a labelled instant on the sampler's timeline.
    func mark(_ label: String) {
        let t = nowSeconds() - startTime
        lock.withLock { marks.append((t, label)) }
    }

    private func loop() {
        var lastCPU = processCPUSeconds()
        var lastSystem = systemCPUTicks()
        var next = nowSeconds() + period
        while lock.withLock({ running }) {
            let sleepFor = next - nowSeconds()
            if sleepFor > 0 { Thread.sleep(forTimeInterval: sleepFor) }
            let now = nowSeconds()
            let overrun = now - next
            next = now + period

            // Arm each probe when nothing is outstanding; the sample is the age
            // of whatever IS outstanding, so a stall shows up while it lasts.
            let mainQAge = armAndAge(now: now, slot: \.mainQArmed) { stamp in
                DispatchQueue.main.async { self.clear(\.mainQArmed, stamp) }
            }
            let runLoopAge = armAndAge(now: now, slot: \.runLoopArmed) { stamp in
                CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                    self.clear(\.runLoopArmed, stamp)
                }
                CFRunLoopWakeUp(CFRunLoopGetMain())
            }
            let poolAge = armAndAge(now: now, slot: \.poolArmed) { stamp in
                Task.detached { self.clear(\.poolArmed, stamp) }
            }

            let cpu = processCPUSeconds()
            let system = systemCPUTicks()
            let sample = Sample(
                t: now - startTime, mainQ: mainQAge, runLoop: runLoopAge, pool: poolAge,
                tick: overrun, procCPU: cpu - lastCPU,
                sysBusy: system.busy - lastSystem.busy, sysIdle: system.idle - lastSystem.idle,
                threads: liveThreadCount())
            lastCPU = cpu
            lastSystem = system
            lock.withLock { samples.append(sample) }
        }
    }

    private func armAndAge(
        now: Double, slot: ReferenceWritableKeyPath<DiagStallSampler, Double?>,
        arm: (Double) -> Void
    ) -> Double {
        let outstanding: Double? = lock.withLock {
            if let armed = self[keyPath: slot] { return armed }
            self[keyPath: slot] = now
            return nil
        }
        if let outstanding { return now - outstanding }
        arm(now)
        return 0
    }

    private func clear(_ slot: ReferenceWritableKeyPath<DiagStallSampler, Double?>, _ stamp: Double)
    {
        lock.withLock { if self[keyPath: slot] == stamp { self[keyPath: slot] = nil } }
    }

    /// A compact CSV of every sample plus the marks, for `Issue.record`.
    func report(title: String) -> String {
        let (rows, points) = lock.withLock { (samples, marks) }
        var text = "DIAG \(title) cores=\(ProcessInfo.processInfo.activeProcessorCount)\n"
        text += "marks: " + points.map { String(format: "%.3f=%@", $0.0, $0.1) }.joined(separator: " ") + "\n"
        text += "t,mainQ,runLoop,pool,tick,procCPU,sysBusy,sysIdle,threads\n"
        for row in rows {
            text += String(
                format: "%.2f,%.3f,%.3f,%.3f,%.3f,%.3f,%.0f,%.0f,%d\n",
                row.t, row.mainQ, row.runLoop, row.pool, row.tick, row.procCPU,
                row.sysBusy, row.sysIdle, row.threads)
        }
        return text
    }
}
