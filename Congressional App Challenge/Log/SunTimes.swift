import Foundation

// Sunrise and sunset from a formula (NOAA's simplified solar equations), so night hours work offline.
// Accurate to a minute or two at Washington latitudes, which is plenty for an hour log.
//
// "Night" = after sunset or before sunrise. WA requires 10 of the 50 hours at night, but the definition used here
// (sunset to sunrise) is an assumption to confirm with DOL / the driving school; change isNight if theirs differs.
enum SunTimes {
    static let fallbackCoordinate = (latitude: 47.61, longitude: -122.33) // Seattle, if a drive had no GPS fix.

    // Sunrise and sunset on the calendar day containing `date` in `timeZone`. nil during polar day or night.
    static func riseSet(on date: Date, latitude: Double, longitude: Double, timeZone: TimeZone = .current) -> (rise: Date, set: Date)? {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        let day = local.dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard let utcMidnight = utc.date(from: day), let dayOfYear = utc.ordinality(of: .day, in: .year, for: utcMidnight) else { return nil }

        let g = 2 * Double.pi / 365 * Double(dayOfYear - 1) // Fractional year at noon, radians.
        let equationOfTime = 229.18 * (0.000075 + 0.001868 * cos(g) - 0.032077 * sin(g) - 0.014615 * cos(2 * g) - 0.040849 * sin(2 * g)) // Minutes.
        let declination = 0.006918 - 0.399912 * cos(g) + 0.070257 * sin(g) - 0.006758 * cos(2 * g) + 0.000907 * sin(2 * g)
            - 0.002697 * cos(3 * g) + 0.00148 * sin(3 * g) // Radians.
        let lat = latitude * .pi / 180
        let zenith = 90.833 * Double.pi / 180 // Sun's center just below the horizon (refraction + sun's radius).
        let cosHourAngle = cos(zenith) / (cos(lat) * cos(declination)) - tan(lat) * tan(declination)
        guard abs(cosHourAngle) <= 1 else { return nil }
        let hourAngle = acos(cosHourAngle) * 180 / .pi // Degrees.

        // Minutes after UTC midnight of that date (can pass 1440 in the Americas; adding them still gives the right moment).
        let rise = 720 - 4 * (longitude + hourAngle) - equationOfTime
        let set = 720 - 4 * (longitude - hourAngle) - equationOfTime
        return (utcMidnight.addingTimeInterval(rise * 60), utcMidnight.addingTimeInterval(set * 60))
    }

    static func isNight(_ date: Date, latitude: Double, longitude: Double, timeZone: TimeZone = .current) -> Bool {
        guard let sun = riseSet(on: date, latitude: latitude, longitude: longitude, timeZone: timeZone) else { return false }
        return date < sun.rise || date >= sun.set
    }

    // Seconds of [start, end] that fall at night, sampled every 30 s.
    static func nightSeconds(from start: Date, to end: Date, latitude: Double, longitude: Double, timeZone: TimeZone = .current) -> Double {
        let step = 30.0
        var total = 0.0
        var t = start
        while t < end {
            let slice = min(step, end.timeIntervalSince(t))
            if isNight(t.addingTimeInterval(slice / 2), latitude: latitude, longitude: longitude, timeZone: timeZone) { total += slice }
            t = t.addingTimeInterval(step)
        }
        return total
    }
}
