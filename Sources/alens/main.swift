import Foundation

// AsyncParsableCommand.main() is async — must be called from an async context.
// Task{} provides that context; RunLoop.main.run() keeps the process alive until
// the command calls exit() (on error) or returns normally (we then call exit(0)).
Task {
    await Alens.main()
    exit(0)
}
RunLoop.main.run()
