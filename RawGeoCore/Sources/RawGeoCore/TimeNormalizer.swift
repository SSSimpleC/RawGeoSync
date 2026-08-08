import Foundation

public enum AmbiguousLocalTimeResolution: String, Hashable, Sendable, Codable {
  case reject
  case earlier
  case later
}

public enum TimeNormalizationError: Error, Hashable, Sendable {
  case invalidTimeZoneIdentifier(String)
  case invalidUTCOffset(Int)
  case invalidDateComponents
  case nonexistentLocalTime
  case ambiguousLocalTime(earlier: Date, later: Date)
}

public struct TimeNormalizer: Sendable {
  public init() {}

  public func normalize(
    _ timestamp: PhotoCaptureTimestamp,
    timeZoneIdentifier: String,
    cameraClockDelta: TimeInterval = 0,
    ambiguousTimeResolution: AmbiguousLocalTimeResolution = .reject
  ) throws -> Date {
    let localInstant: Date
    if let originalOffset = timestamp.originalUTCOffsetSeconds {
      guard abs(originalOffset) <= 18 * 60 * 60,
        let fixedTimeZone = TimeZone(secondsFromGMT: originalOffset)
      else {
        throw TimeNormalizationError.invalidUTCOffset(originalOffset)
      }
      localInstant = try uniqueDate(for: timestamp, in: fixedTimeZone)
    } else {
      guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
        throw TimeNormalizationError.invalidTimeZoneIdentifier(timeZoneIdentifier)
      }
      let candidates = try candidateDates(for: timestamp, in: timeZone)
      switch candidates.count {
      case 0:
        throw TimeNormalizationError.nonexistentLocalTime
      case 1:
        localInstant = candidates[0]
      default:
        let earlier = candidates[0]
        let later = candidates[candidates.count - 1]
        switch ambiguousTimeResolution {
        case .reject:
          throw TimeNormalizationError.ambiguousLocalTime(earlier: earlier, later: later)
        case .earlier:
          localInstant = earlier
        case .later:
          localInstant = later
        }
      }
    }
    return localInstant.addingTimeInterval(-cameraClockDelta)
  }

  private func uniqueDate(for timestamp: PhotoCaptureTimestamp, in timeZone: TimeZone) throws
    -> Date
  {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    guard let date = calendar.date(from: timestamp.dateComponents),
      components(of: date, in: timeZone).matches(timestamp)
    else {
      throw TimeNormalizationError.invalidDateComponents
    }
    return date
  }

  private func candidateDates(for timestamp: PhotoCaptureTimestamp, in timeZone: TimeZone) throws
    -> [Date]
  {
    var utcCalendar = Calendar(identifier: .gregorian)
    utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
    guard let naiveUTCDate = utcCalendar.date(from: timestamp.dateComponents) else {
      throw TimeNormalizationError.invalidDateComponents
    }

    var possibleOffsets = Set<Int>()
    for hour in stride(from: -48, through: 48, by: 6) {
      possibleOffsets.insert(
        timeZone.secondsFromGMT(for: naiveUTCDate.addingTimeInterval(TimeInterval(hour * 3_600)))
      )
    }

    return possibleOffsets.compactMap { offset -> Date? in
      let candidate = naiveUTCDate.addingTimeInterval(TimeInterval(-offset))
      guard timeZone.secondsFromGMT(for: candidate) == offset,
        components(of: candidate, in: timeZone).matches(timestamp)
      else {
        return nil
      }
      return candidate
    }
    .sorted()
  }

  private func components(of date: Date, in timeZone: TimeZone) -> DateComponents {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second, .nanosecond],
      from: date
    )
  }
}

extension PhotoCaptureTimestamp {
  fileprivate var dateComponents: DateComponents {
    DateComponents(
      year: year,
      month: month,
      day: day,
      hour: hour,
      minute: minute,
      second: second,
      nanosecond: nanosecond
    )
  }
}

extension DateComponents {
  fileprivate func matches(_ timestamp: PhotoCaptureTimestamp) -> Bool {
    year == timestamp.year
      && month == timestamp.month
      && day == timestamp.day
      && hour == timestamp.hour
      && minute == timestamp.minute
      && second == timestamp.second
      && abs((nanosecond ?? 0) - timestamp.nanosecond) <= 1_000
  }
}
