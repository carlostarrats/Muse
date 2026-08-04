//
//  ErrorRedaction.swift
//  Muse
//
//  What an error is allowed to say in the unified system log.
//
//  `NSLog`'s `%@` arguments are PUBLIC there — readable by any other process
//  and captured in every sysdiagnose — so an app whose privacy label is "Data
//  Not Collected" must not put a user's file or folder names into one. Round 15
//  removed the paths those messages interpolated by hand.
//
//  It removed the wrong half. A Foundation filesystem error CARRIES the paths,
//  and `String(describing:)` prints its whole `userInfo`:
//
//      Error Domain=NSCocoaErrorDomain Code=4 "“Holiday in Tuscany 2019.jpg”
//      couldn’t be moved to “Nope” …" UserInfo={NSSourceFilePathErrorKey=/…/
//      Holiday in Tuscany 2019.jpg, NSDestinationFilePath=/…/Private Album.jpg,
//      NSFilePath=…, NSURL=file:///…}
//
//  — source path, destination path and file name, from the one argument that
//  looked like a safe technical detail. `localizedDescription` is no better:
//  it opens with the file's name. So the rule cannot be "don't interpolate a
//  path"; it has to be "don't hand an error to a logger at all". This is the
//  seam that makes the safe thing the easy thing.
//
//  What survives is what makes a report actionable: which error domain, which
//  code, and the underlying POSIX code — enough to tell "disk full" from
//  "permission denied" from "no such file", and nothing about whose file it was.
//

import Foundation

nonisolated enum ErrorRedaction {

    /// A log-safe description: domain and code only, plus the underlying
    /// error's domain/code when there is one. Never any part of `userInfo`,
    /// and never `localizedDescription` (which names the file).
    static func summary(of error: Error) -> String {
        let ns = error as NSError
        var out = "\(ns.domain)(\(ns.code))"
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            out += " <- \(underlying.domain)(\(underlying.code))"
        }
        return out
    }
}
