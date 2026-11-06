#if canImport(Darwin)
import Darwin
#endif

/// Whether a thread's file accesses materialize — download — a dataless file: one iCloud Drive's Optimize Mac
/// Storage, or another File Provider, evicted, with `SF_DATALESS` in its `st_flags` (`sys/stat.h`; `ls -lO`
/// shows `dataless`).
///
/// `man setiopolicy_np`: `IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES` sets this per thread or per process. A
/// thread follows its process unless set; a process follows the system default,
/// `IOPOL_MATERIALIZE_DATALESS_FILES_OFF`, unless set; and a new process inherits its parent's. So what an access
/// does with a dataless file depends on how the process was launched, unless the thread sets it. With
/// materialization off, an access that needs it fails `EDEADLK` (`man 2 open`, for a dataless directory).
///
/// A platform with no dataless files runs every body as it is.
public enum DatalessMaterialization: Sendable, Hashable {
    /// Accessing a dataless file fails `EDEADLK`, downloading nothing.
    case off
    /// Accessing a dataless file downloads it first.
    case on

    /// Runs `body` with this thread's policy set to `self`, then restores the thread's earlier one. `body` is
    /// synchronous, so every access it makes is this thread's.
    public func during<Value, Failure: Error>(_ body: () throws(Failure) -> Value) throws(Failure) -> Value {
        #if canImport(Darwin)
        let earlier = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        let set = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, policy)
        assert(set == 0, "setiopolicy_np refused a dataless-materialization policy: errno \(errno)")
        defer {
            if earlier >= 0 {
                _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, earlier)
            }
        }
        #endif
        return try body()
    }

    /// This thread's own policy, or nil when it follows its process.
    public static var ofThisThread: DatalessMaterialization? {
        #if canImport(Darwin)
        switch getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
            & IOPOL_MATERIALIZE_DATALESS_FILES_BASIC_MASK
        {
        case IOPOL_MATERIALIZE_DATALESS_FILES_OFF: return .off
        case IOPOL_MATERIALIZE_DATALESS_FILES_ON: return .on
        default: return nil
        }
        #else
        return nil
        #endif
    }

    #if canImport(Darwin)
    private var policy: Int32 {
        switch self {
        case .off: IOPOL_MATERIALIZE_DATALESS_FILES_OFF
        case .on: IOPOL_MATERIALIZE_DATALESS_FILES_ON
        }
    }
    #endif
}
