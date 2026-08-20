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
