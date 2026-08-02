//
//  TestTimeZone.swift
//  MuseTests
//
//  Pins the zone SQLite's `'localtime'` modifier resolves against, so a
//  date-part assertion means the same thing on a CI box in UTC and on a laptop
//  in California.
//
//  SQLite reads the zone from the C library, not from Foundation, so this is
//  `setenv` + `tzset` rather than anything on `TimeZone`. Queries that mix a
//  Swift-side `Calendar` with a SQL-side date part are the ones that need it:
//  `SearchFacets.distinctYears` is the standing case.
//
//  `setenv` is process-global, which would be a hazard if tests ran concurrently
//  in one process. They do not: the scheme sets no `parallelizable` attribute
//  (so testing is serial), and even when Xcode parallelizes it distributes
//  classes across separate runner PROCESSES, which get their own environment.
//  The `defer` restore holds the invariant either way.
//

import Foundation
import XCTest

extension XCTestCase {

    /// Run `body` with the process time zone pinned to `tz`, restoring whatever
    /// was there before — including the un-set case, which must go back to
    /// un-set rather than to a guess at the machine's zone.
    func withTimeZone(_ tz: String, _ body: () throws -> Void) rethrows {
        let previous = getenv("TZ").map { String(cString: $0) }
        setenv("TZ", tz, 1)
        tzset()
        defer {
            if let previous { setenv("TZ", previous, 1) } else { unsetenv("TZ") }
            tzset()
        }
        try body()
    }
}
