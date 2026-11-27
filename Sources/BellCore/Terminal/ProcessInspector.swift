import Darwin

/// Reads the parent and controlling terminal of a process from the kernel.
///
/// Uses `sysctl(KERN_PROC_PID)` rather than `proc_pidinfo`: the chain from a terminal
/// app down to `claude` passes through `/usr/bin/login`, which runs as root, and
/// `proc_pidinfo` refuses to describe another user's process.
public enum ProcessInspector {
    public static func parent(of pid: Int32) -> Int32? {
        guard let info = kinfo(pid), info.kp_eproc.e_ppid > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// The terminal device a process is attached to, like "/dev/ttys001".
    public static func ttyPath(of pid: Int32) -> String? {
        guard let info = kinfo(pid), info.kp_eproc.e_tdev != -1 else { return nil }
        guard let name = devname(info.kp_eproc.e_tdev, S_IFCHR) else { return nil }
        let path = "/dev/" + String(cString: name)
        return TerminalLocator.isTTYPath(path) ? path : nil
    }

    private static func kinfo(_ pid: Int32) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }
}
