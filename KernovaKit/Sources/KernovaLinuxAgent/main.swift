#if os(Linux)
AgentShell.main(CommandLine.arguments)
#else
fatalError("kernova-agent runs only on Linux")
#endif
