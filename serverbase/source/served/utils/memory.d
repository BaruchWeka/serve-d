module served.utils.memory;

/// Calls `destro!false` on the value or just `destroy` if not supported.
/// Makes the value undefined/unset after calling so it shouldn't be used anymore.
void destroyUnset(T)(ref T value)
		if (__traits(compiles, destroy!false(value)) || __traits(compiles, destroy(value)))
{
	static if (__traits(compiles, destroy!false(value)))
		destroy!false(value);
	else
		destroy(value);
}

/// ditto
deprecated("Type doesn't support to be destroyed in this D version") void destroyUnset(T)(ref T value)
		if (!__traits(compiles, destroy!false(value)) && !__traits(compiles, destroy(value)))
{
}

version (CRuntime_Glibc)
{
	private extern (C) int malloc_trim(size_t pad) nothrow @nogc;
}

/// Asks the C runtime to hand free heap pages back to the OS. `GC.minimize`
/// only covers the D heap; anything reaching the C allocator (libdparse's
/// `RollbackAllocator`, the emsi containers) stays mapped in the glibc arenas
/// otherwise. No-op where the C runtime has no such call.
void trimCRuntimeHeap() nothrow @nogc
{
	version (CRuntime_Glibc)
		malloc_trim(0);
}

version (linux)
{
	/// Resident set size in bytes, or 0 if it can't be read. Parsed out of
	/// `/proc/self/statm` with raw syscalls so it stays callable from the GC path.
	size_t residentBytes() nothrow @nogc
	{
		import core.sys.posix.fcntl : open, O_RDONLY;
		import core.sys.posix.unistd : close, read, sysconf, _SC_PAGESIZE;

		immutable fd = open("/proc/self/statm", O_RDONLY);
		if (fd < 0)
			return 0;
		scope (exit)
			close(fd);

		char[128] buf;
		immutable n = read(fd, buf.ptr, buf.length - 1);
		if (n <= 0)
			return 0;

		// "size resident shared text lib data dt", all in pages; we want field 2.
		size_t i = 0;
		while (i < n && buf[i] != ' ')
			i++;
		while (i < n && buf[i] == ' ')
			i++;

		size_t pages;
		bool any;
		for (; i < n && buf[i] >= '0' && buf[i] <= '9'; i++)
		{
			pages = pages * 10 + (buf[i] - '0');
			any = true;
		}
		if (!any)
			return 0;

		immutable pageSize = sysconf(_SC_PAGESIZE);
		if (pageSize <= 0)
			return 0;
		return pages * cast(size_t) pageSize;
	}
}
else
{
	/// ditto
	size_t residentBytes() nothrow @nogc { return 0; }
}

/// Calls `GC.minimize` until it stops handing memory back, then returns how many
/// calls it took. A runtime that releases free pool pages to the OS does so with a
/// per-call budget, so one call after a big indexing run can leave gigabytes mapped
/// that a later call would return. Stops as soon as a call gains less than
/// `minGainBytes`, so where nothing extra comes back -- every stock runtime, and any
/// platform where RSS can't be read -- this costs exactly one call, as before.
int minimizeUntilSettled(size_t minGainBytes = 32 * 1024 * 1024, int maxRounds = 64) nothrow
{
	import core.memory : GC;

	int rounds;
	foreach (_; 0 .. maxRounds)
	{
		immutable before = residentBytes();
		GC.minimize();
		rounds++;
		immutable after = residentBytes();
		// Unmeasurable, grew, or the gain stopped being worth another pass.
		if (before == 0 || after == 0 || after >= before || before - after < minGainBytes)
			break;
	}
	return rounds;
}
