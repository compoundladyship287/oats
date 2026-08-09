import AVFoundation
import Foundation

// DemoBuilder — turns the raw screen recording into the finished demo film.
//
//   DemoBuilder contact <in.mov> <outDir> [every]   dump frames to choose cuts
//   DemoBuilder build   <in.mov> <out.mp4>          render the final video

let arguments = CommandLine.arguments

func usage() -> Never {
    print("""
        usage:
          DemoBuilder contact <input.mov> <outputDir> [everySeconds]
          DemoBuilder build   <input.mov> <output.mp4>
        """)
    exit(2)
}

guard arguments.count >= 2 else { usage() }

let semaphore = DispatchSemaphore(value: 0)
var failure: Error?

Task {
    do {
        switch arguments[1] {
        case "contact":
            guard arguments.count >= 4 else { usage() }
            try await Contact.run(
                input: URL(fileURLWithPath: arguments[2]),
                outputDirectory: URL(fileURLWithPath: arguments[3]),
                every: arguments.count > 4 ? Double(arguments[4]) ?? 2 : 2)
        case "build":
            guard arguments.count >= 4 else { usage() }
            try await DemoFilm.build(
                input: URL(fileURLWithPath: arguments[2]),
                output: URL(fileURLWithPath: arguments[3]))
        default:
            usage()
        }
    } catch {
        failure = error
    }
    semaphore.signal()
}

semaphore.wait()
if let failure {
    FileHandle.standardError.write("error: \(failure)\n".data(using: .utf8)!)
    exit(1)
}
