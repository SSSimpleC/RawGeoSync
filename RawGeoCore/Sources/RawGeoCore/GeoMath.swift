import Foundation

public enum GeoMath {
  private static let earthRadiusMeters = 6_371_000.0

  public static func distance(from first: GeoCoordinate, to second: GeoCoordinate) -> Double {
    let latitude1 = first.latitude * .pi / 180
    let latitude2 = second.latitude * .pi / 180
    let latitudeDelta = (second.latitude - first.latitude) * .pi / 180
    let longitudeDelta = (second.longitude - first.longitude) * .pi / 180

    let value =
      sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
      + cos(latitude1) * cos(latitude2)
      * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
    return earthRadiusMeters * 2 * atan2(sqrt(value), sqrt(max(0, 1 - value)))
  }

  public static func interpolate(
    from first: GeoCoordinate,
    to second: GeoCoordinate,
    fraction: Double
  ) -> GeoCoordinate {
    let fraction = min(1, max(0, fraction))
    let firstVector = unitVector(for: first)
    let secondVector = unitVector(for: second)
    let dot = min(
      1,
      max(
        -1,
        firstVector.x * secondVector.x
          + firstVector.y * secondVector.y
          + firstVector.z * secondVector.z))
    let omega = acos(dot)

    let vector: (x: Double, y: Double, z: Double)
    if omega < 1e-12 {
      vector = firstVector
    } else if abs(.pi - omega) < 1e-10 {
      let latitude = first.latitude + (second.latitude - first.latitude) * fraction
      var longitudeDelta = second.longitude - first.longitude
      if longitudeDelta > 180 { longitudeDelta -= 360 }
      if longitudeDelta < -180 { longitudeDelta += 360 }
      let longitude = normalizedLongitude(first.longitude + longitudeDelta * fraction)
      return GeoCoordinate(latitude: latitude, longitude: longitude)
    } else {
      let denominator = sin(omega)
      let firstWeight = sin((1 - fraction) * omega) / denominator
      let secondWeight = sin(fraction * omega) / denominator
      vector = (
        firstVector.x * firstWeight + secondVector.x * secondWeight,
        firstVector.y * firstWeight + secondVector.y * secondWeight,
        firstVector.z * firstWeight + secondVector.z * secondWeight
      )
    }

    let latitude = atan2(vector.z, hypot(vector.x, vector.y)) * 180 / .pi
    let longitude = atan2(vector.y, vector.x) * 180 / .pi
    return GeoCoordinate(latitude: latitude, longitude: normalizedLongitude(longitude))
  }

  private static func unitVector(for coordinate: GeoCoordinate) -> (x: Double, y: Double, z: Double)
  {
    let latitude = coordinate.latitude * .pi / 180
    let longitude = coordinate.longitude * .pi / 180
    return (
      cos(latitude) * cos(longitude),
      cos(latitude) * sin(longitude),
      sin(latitude)
    )
  }

  private static func normalizedLongitude(_ longitude: Double) -> Double {
    var result = longitude.truncatingRemainder(dividingBy: 360)
    if result > 180 { result -= 360 }
    if result < -180 { result += 360 }
    return result
  }
}
