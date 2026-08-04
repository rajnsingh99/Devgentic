//
//  URLPathComparison.swift
//  Devgentic
//
//  Created 2026-08-03.
//
//  Comparing two file URLs for "same location" is a trap that bit this codebase in four
//  separate places, so the rule lives here once.
//
//  ⚠️ `URL` equality — even after `standardizedFileURL` — is NOT location equality.
//  `standardizedFileURL` resolves `.` and `..` but PRESERVES the directory flag, so:
//
//      URL(fileURLWithPath: "/a/b")   ->  file:///a/b
//      URL(fileURLWithPath: "/a/b/")  ->  file:///a/b/     // != the above
//
//  and the two sides of a comparison routinely arrive flavoured differently, because the API
//  that produced them decides:
//    • `deletingLastPathComponent()`      -> directory-flavoured (trailing slash)
//    • `appendingPathComponent(_:)`       -> file-flavoured (no trailing slash)
//    • `URL(resolvingBookmarkData:)`      -> directory-flavoured for a folder
//    • `URL(fileURLWithPath:)`            -> asks the FILESYSTEM, so it depends on what exists
//    • `FileManager.temporaryDirectory`   -> directory-flavoured
//
//  Separately, `standardizedFileURL` does not resolve SYMLINKS — only `resolvingSymlinksInPath`
//  does, and only `sameLocation` below pays for it.
//
//  ⚠️ Measured on macOS 15, because the obvious guess is wrong: the `/var` ↔ `/private/var`
//  pair is NOT an instance of this. `resolvingSymlinksInPath()` does not rewrite `/var` to
//  `/private/var`; it strips a leading `/private`, and `standardizedFileURL` strips it too. So
//  both helpers already agree on that pair. The real difference between them is a genuine
//  user-created symlink, which diverges lexically and only `sameLocation` sees through.
//

import Foundation

extension URL {

    /// True when both URLs name the same filesystem location.
    ///
    /// Compares `.path`, which drops the trailing-slash distinction, after resolving symlinks
    /// so the `/var` ↔ `/private/var` pair agrees. Use this instead of `==` for any "is this
    /// the same file/folder" question.
    ///
    /// ⚠️ Resolution touches the filesystem, so this is a comparison for *decisions about real
    /// paths*, not something to call in a tight loop. For paths that cannot be symlinked apart
    /// — both built from the same root in the same function — `sameLocationLexically(as:)` is
    /// enough and does no I/O.
    func sameLocation(as other: URL) -> Bool {
        resolvingSymlinksInPath().path == other.resolvingSymlinksInPath().path
    }

    /// Trailing-slash-insensitive comparison with **no** filesystem access, and therefore no
    /// symlink resolution. Correct when both sides are derived from the same root within the
    /// app's own storage.
    func sameLocationLexically(as other: URL) -> Bool {
        standardizedFileURL.path == other.standardizedFileURL.path
    }
}
