import Darwin
import ReqsCLI

exit(await CLI.run(Array(CommandLine.arguments.dropFirst()), environment: .live))
