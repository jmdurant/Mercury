//
//  ShareViewController.swift
//  ClawWatch Share
//
//  Share Extension — accepts shared text/links and queues them into the
//  app group; the main app picks up pending shares and sends them.
//

import UIKit
import Social

final class ShareViewController: SLComposeServiceViewController {

    private let appGroupId = "group.com.doctordurant.clawwatch"

    override func isContentValid() -> Bool {
        return !(contentText ?? "").isEmpty
    }

    override func didSelectPost() {
        let text = contentText ?? ""
        let defaults = UserDefaults(suiteName: appGroupId)
        var pending = defaults?.stringArray(forKey: "pendingShares") ?? []
        pending.append(text)
        defaults?.set(pending, forKey: "pendingShares")

        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    override func configurationItems() -> [Any]! {
        return []
    }
}
