import KernovaFileTree
import Testing

/// The cursor's moves against an in-memory file system, so the suite runs on
/// every platform the package builds for.
@Suite("DirectoryCursor")
struct DirectoryCursorTests {
    @Test("down and back up returns each frame, holding at most two directories, and closes the last at its end")
    func walksDownAndUp() throws {
        let fileSystem = MemoryFileSystem()
        let names = (0..<6).map { "level\($0)" }
        var node = fileSystem.root
        for name in names { node = node.add(name) }

        do {
            var cursor = DirectoryCursor(
                fileSystem: fileSystem, descriptor: fileSystem.hand(fileSystem.root),
                status: fileSystem.root.status, frame: "top")
            for name in names {
                let child = try fileSystem.openDirectory(Array(name.utf8), in: cursor.descriptor)
                cursor.descend(into: child, status: try fileSystem.status(of: child), frame: name)
                let parent = cursor.parentFrame
                #expect(parent != nil)
            }
            let bottom = cursor.frame
            #expect(bottom == "level5")
            var left: [String] = []
            while !cursor.isAtTop { left.append(try cursor.ascend()) }
            #expect(left == names.reversed())
            let (top, aboveTop) = (cursor.frame, cursor.parentFrame)
            #expect(top == "top" && aboveTop == nil)
            #expect(fileSystem.open.count == 1)
        }
        #expect(fileSystem.open.isEmpty)
        #expect(fileSystem.mostOpen == 2)
    }

    @Test("a parent that is not the directory the cursor came down from stops it where it is")
    func movedParentStops() throws {
        let fileSystem = MemoryFileSystem()
        let a = fileSystem.root.add("a")
        let b = a.add("b")
        b.parentOverride = fileSystem.root.add("elsewhere")

        var cursor = DirectoryCursor(
            fileSystem: fileSystem, descriptor: fileSystem.hand(fileSystem.root), status: fileSystem.root.status,
            frame: "top")
        for name in ["a", "b"] {
            let child = try fileSystem.openDirectory(Array(name.utf8), in: cursor.descriptor)
            cursor.descend(into: child, status: try fileSystem.status(of: child), frame: name)
        }
        let at = cursor.descriptor
        #expect(throws: DirectoryCursorFailure.moved) { _ = try cursor.ascend() }
        let (stayed, frame) = (cursor.descriptor, cursor.frame)
        #expect(stayed == at && frame == "b")
        #expect(fileSystem.open.keys.sorted() == [at])
    }

    @Test("a parent that cannot be reopened is the call's failure, and the cursor stays")
    func unreachableParentStops() throws {
        let fileSystem = MemoryFileSystem()
        fileSystem.root.add("a")
        var cursor = DirectoryCursor(
            fileSystem: fileSystem, descriptor: fileSystem.hand(fileSystem.root), status: fileSystem.root.status,
            frame: "top")
        let child = try fileSystem.openDirectory(Array("a".utf8), in: cursor.descriptor)
        cursor.descend(into: child, status: try fileSystem.status(of: child), frame: "a")
        fileSystem.parentRefusal = MemoryFileSystem.denied

        #expect(throws: DirectoryCursorFailure.system(MemoryFileSystem.denied)) { _ = try cursor.ascend() }
        let stayed = cursor.descriptor
        #expect(stayed == child)
        #expect(fileSystem.open.keys.sorted() == [child])
    }

    @Test("leaving runs with both directories open, and its failure keeps the cursor where it was")
    func leavingRunsBeforeTheMove() throws {
        struct Refused: Error {}
        let fileSystem = MemoryFileSystem()
        fileSystem.root.add("a")
        var cursor = DirectoryCursor(
            fileSystem: fileSystem, descriptor: fileSystem.hand(fileSystem.root), status: fileSystem.root.status,
            frame: "top")
        let child = try fileSystem.openDirectory(Array("a".utf8), in: cursor.descriptor)
        cursor.descend(into: child, status: try fileSystem.status(of: child), frame: "a")

        #expect(throws: Refused.self) {
            _ = try cursor.ascend { descriptor, frame in
                #expect(descriptor == child && frame == "a")
                #expect(fileSystem.open.count == 2)
                throw Refused()
            }
        }
        let stayed = cursor.descriptor
        #expect(stayed == child)
        #expect(fileSystem.open.keys.sorted() == [child])

        var seen: [String] = []
        #expect(try cursor.ascend { _, frame in seen.append(frame) } == "a")
        #expect(seen == ["a"])
        let isAtTop = cursor.isAtTop
        #expect(isAtTop)
    }
}

/// A tree of directories held in memory, handing out descriptors and counting
/// how many are open.
private final class MemoryFileSystem: TreeFileSystem {
    static let missing = TreeFileSystemError(code: 2)
    static let badDescriptor = TreeFileSystemError(code: 9)
    static let denied = TreeFileSystemError(code: 13)

    final class Node {
        let inode: UInt64
        private(set) var children: [[UInt8]: Node] = [:]
        weak var parent: Node?
        /// Where `..` leads instead of `parent`.
        var parentOverride: Node?
        private unowned let fileSystem: MemoryFileSystem

        init(fileSystem: MemoryFileSystem) {
            self.fileSystem = fileSystem
            inode = fileSystem.mintInode()
        }

        var status: FileStatus { FileStatus(kind: .directory, permissions: 0o755, device: 7, inode: inode) }

        @discardableResult
        func add(_ name: String) -> Node {
            let child = Node(fileSystem: fileSystem)
            child.parent = self
            children[Array(name.utf8)] = child
            return child
        }
    }

    private var nextInode: UInt64 = 2
    private var nextDescriptor: Int32 = 100
    private(set) var open: [Int32: Node] = [:]
    private(set) var mostOpen = 0
    private(set) lazy var root = Node(fileSystem: self)
    /// What reopening a parent fails with.
    var parentRefusal: TreeFileSystemError?

    fileprivate func mintInode() -> UInt64 {
        defer { nextInode += 1 }
        return nextInode
    }

    func hand(_ node: Node) -> Int32 {
        nextDescriptor += 1
        open[nextDescriptor] = node
        mostOpen = max(mostOpen, open.count)
        return nextDescriptor
    }

    private func node(_ descriptor: Int32) throws(TreeFileSystemError) -> Node {
        guard let node = open[descriptor] else { throw Self.badDescriptor }
        return node
    }

    func status(of name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> FileStatus {
        guard let child = try node(directory).children[name] else { throw Self.missing }
        return child.status
    }

    func status(of descriptor: Int32) throws(TreeFileSystemError) -> FileStatus { try node(descriptor).status }

    func openDirectory(_ name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> Int32 {
        guard let child = try node(directory).children[name] else { throw Self.missing }
        return hand(child)
    }

    func openParent(of directory: Int32) throws(TreeFileSystemError) -> Int32 {
        if let parentRefusal { throw parentRefusal }
        let node = try node(directory)
        guard let up = node.parentOverride ?? node.parent else { throw Self.missing }
        return hand(up)
    }

    func openFile(_ name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> Int32 { throw Self.missing }

    func names(in directory: Int32) throws(TreeFileSystemError) -> [[UInt8]] {
        Array(try node(directory).children.keys)
    }

    func linkTarget(of name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> [UInt8] {
        throw Self.missing
    }

    func read(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer) throws(TreeFileSystemError) -> Int {
        throw Self.badDescriptor
    }

    func close(_ descriptor: Int32) {
        let closed = open.removeValue(forKey: descriptor)
        precondition(closed != nil, "closed descriptor \(descriptor) twice")
    }
}
