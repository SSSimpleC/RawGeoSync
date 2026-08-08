import Darwin
import Foundation

public struct ExecutableInvocation: Hashable, Sendable {
  public let executableURL: URL
  public let arguments: [String]
  public let environment: [String: String]
  public let standardInput: Data?

  public init(
    executableURL: URL,
    arguments: [String],
    environment: [String: String] = [:],
    standardInput: Data? = nil
  ) {
    self.executableURL = executableURL
    self.arguments = arguments
    self.environment = environment
    self.standardInput = standardInput
  }
}

public struct ExecutableResult: Hashable, Sendable {
  public let terminationStatus: Int32
  public let standardOutput: Data
  public let standardError: Data

  public init(terminationStatus: Int32, standardOutput: Data, standardError: Data) {
    self.terminationStatus = terminationStatus
    self.standardOutput = standardOutput
    self.standardError = standardError
  }
}

public protocol ExecutableRunning: Sendable {
  func run(_ invocation: ExecutableInvocation, timeout: Duration) async throws -> ExecutableResult
}

private final class LockedData: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = Data()

  func append(_ data: Data) {
    lock.withLock { storage.append(data) }
  }

  func value() -> Data {
    lock.withLock { storage }
  }
}

private final class RunningProcess: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?

  func store(_ process: Process) {
    lock.withLock { self.process = process }
  }

  func clear() {
    lock.withLock { process = nil }
  }

  func terminate() {
    let running = lock.withLock { process }
    guard let running, running.isRunning else { return }
    running.terminate()
    let processIdentifier = running.processIdentifier
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
      if kill(processIdentifier, 0) == 0 {
        _ = kill(processIdentifier, SIGKILL)
      }
    }
  }
}

public struct ProcessExecutableRunner: ExecutableRunning {
  public init() {}

  public func run(_ invocation: ExecutableInvocation, timeout: Duration) async throws
    -> ExecutableResult
  {
    let runningProcess = RunningProcess()

    return try await withTaskCancellationHandler {
      try await withThrowingTaskGroup(of: ExecutableResult.self) { group in
        group.addTask {
          try await Self.execute(invocation, runningProcess: runningProcess)
        }
        group.addTask {
          try await Task.sleep(for: timeout)
          throw MetadataInfrastructureError.timedOut
        }

        do {
          guard let result = try await group.next() else {
            throw MetadataInfrastructureError.cancelled
          }
          group.cancelAll()
          return result
        } catch {
          runningProcess.terminate()
          group.cancelAll()
          if error is CancellationError {
            throw MetadataInfrastructureError.cancelled
          }
          throw error
        }
      }
    } onCancel: {
      runningProcess.terminate()
    }
  }

  private static func execute(
    _ invocation: ExecutableInvocation,
    runningProcess: RunningProcess
  ) async throws -> ExecutableResult {
    try await withCheckedThrowingContinuation { continuation in
      let process = Process()
      let standardOutput = Pipe()
      let standardError = Pipe()
      let outputData = LockedData()
      let errorData = LockedData()

      process.executableURL = invocation.executableURL
      process.arguments = invocation.arguments
      if !invocation.environment.isEmpty {
        process.environment = ProcessInfo.processInfo.environment.merging(
          invocation.environment,
          uniquingKeysWith: { _, new in new }
        )
      }
      process.standardOutput = standardOutput
      process.standardError = standardError

      let inputPipe: Pipe?
      if invocation.standardInput != nil {
        let pipe = Pipe()
        process.standardInput = pipe
        inputPipe = pipe
      } else {
        inputPipe = nil
      }

      standardOutput.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        if !data.isEmpty { outputData.append(data) }
      }
      standardError.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        if !data.isEmpty { errorData.append(data) }
      }

      process.terminationHandler = { process in
        standardOutput.fileHandleForReading.readabilityHandler = nil
        standardError.fileHandleForReading.readabilityHandler = nil
        outputData.append(standardOutput.fileHandleForReading.readDataToEndOfFile())
        errorData.append(standardError.fileHandleForReading.readDataToEndOfFile())
        runningProcess.clear()
        continuation.resume(
          returning: ExecutableResult(
            terminationStatus: process.terminationStatus,
            standardOutput: outputData.value(),
            standardError: errorData.value()
          ))
      }

      do {
        runningProcess.store(process)
        try process.run()
        if let input = invocation.standardInput, let inputPipe {
          inputPipe.fileHandleForWriting.write(input)
          try? inputPipe.fileHandleForWriting.close()
        }
      } catch {
        runningProcess.clear()
        standardOutput.fileHandleForReading.readabilityHandler = nil
        standardError.fileHandleForReading.readabilityHandler = nil
        continuation.resume(throwing: error)
      }
    }
  }
}
