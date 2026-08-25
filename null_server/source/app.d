module app;

static import null_server.extension;

import core.time : msecs;

import served.serverbase;

mixin LanguageServerRouter!(null_server.extension) server;

// The main loop resumes fibers once per iteration, so a handler that yields N
// times needs N iterations. macOS runners deliver a nominal 10ms sleep in ~50ms,
// which put testPartial3's 100 yields at 3-4.5s against the test's 5s watchdog
// and made the stdio test flaky. Nothing here needs the production cadence.
enum loopIterationDelay = 1.msecs;

int main(string[] args)
{
	return server.run(loopIterationDelay) ? 0 : 1;
}
