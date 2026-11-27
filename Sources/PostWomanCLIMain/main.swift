import Darwin
import PostWomanCLI

exit(await CLI.run(Array(CommandLine.arguments.dropFirst()), environment: .live))
