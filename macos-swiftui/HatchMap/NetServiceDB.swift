import SwiftUI
import Foundation
import AppKit
import Darwin
import Network
import UserNotifications

// MARK: - Service fingerprint database (domain / org -> app, purpose, category)
// Answers "what app/service is this" for the local Mac (naming the destination service)
// AND for other devices (inferring the app they run from the domains they contact).

struct ServiceHit { let name: String; let vendor: String; let purpose: String; let category: String; let icon: String; let confidence: String }

final class ServiceDB {
    static let shared = ServiceDB()
    private struct Rule { let pat: String; let name: String; let vendor: String; let purpose: String; let category: String; let icon: String; let conf: String }
    private var rules: [Rule] = []
    private static func r(_ pat: String, _ name: String, _ vendor: String, _ purpose: String, _ cat: String, _ icon: String, _ conf: String = "confirmed") -> Rule {
        Rule(pat: pat, name: name, vendor: vendor, purpose: purpose, category: cat, icon: icon, conf: conf)
    }
    init() {
        let R = ServiceDB.r
        rules = [
            // Apple
            R("push.apple","Apple Push","Apple","Push notifications & iMessage delivery","Apple / system","bell.badge","confirmed"),
            R("gateway.icloud","iCloud","Apple","iCloud sync, photos & backup","Apple / system","icloud","confirmed"),
            R("icloud","iCloud","Apple","iCloud sync, photos & backup","Apple / system","icloud","confirmed"),
            R("mesu.apple","Apple Software Update","Apple","Downloading a software update","Apple / system","arrow.down.circle","confirmed"),
            R("swcdn.apple","Apple Software Update","Apple","Downloading a software update","Apple / system","arrow.down.circle","confirmed"),
            R("swscan.apple","Apple Software Update","Apple","Checking for software updates","Apple / system","arrow.down.circle","confirmed"),
            R("gs-loc.apple","Apple Location","Apple","Location services lookup","Apple / system","location","confirmed"),
            R("captive.apple","Apple Connectivity","Apple","Checking if Wi-Fi has internet","Apple / system","wifi","confirmed"),
            R("guzzoni.apple","Siri","Apple","Siri voice request","Apple / system","mic","confirmed"),
            R("music.apple","Apple Music","Apple","Music streaming","Music","music.note","confirmed"),
            R("itunes.apple","Apple Media","Apple","App Store / iTunes media","Apple / system","bag","confirmed"),
            R("tv.apple","Apple TV+","Apple","Video streaming","Streaming","tv","confirmed"),
            R("ocsp.apple","Apple Certificate Check","Apple","Verifying a certificate","Apple / system","checkmark.shield","confirmed"),
            R("ocsp2.apple","Apple Certificate Check","Apple","Verifying a certificate","Apple / system","checkmark.shield","confirmed"),
            R("cdn-apple","Apple CDN","Apple","Apple content download","Apple / system","arrow.down","confirmed"),
            R("aaplimg","Apple CDN","Apple","Apple content download","Apple / system","arrow.down","confirmed"),
            R("fmip","Find My","Apple","Locating an Apple device","Apple / system","location.magnifyingglass","confirmed"),
            // Google / YouTube
            R("googlevideo","YouTube","Google","Video streaming","Streaming","play.rectangle","confirmed"),
            R("youtube","YouTube","Google","Video streaming","Streaming","play.rectangle","confirmed"),
            R("ytimg","YouTube","Google","Video thumbnails & assets","Streaming","play.rectangle","confirmed"),
            R("ggpht","YouTube","Google","Video images","Streaming","play.rectangle","confirmed"),
            R("gvt1","Google Update","Google","App or update download","Cloud / CDN","arrow.down.circle","confirmed"),
            R("gvt2","Google Update","Google","App or update download","Cloud / CDN","arrow.down.circle","confirmed"),
            R("dl.google","Google Download","Google","App or update download","Cloud / CDN","arrow.down.circle","confirmed"),
            R("mail.google","Gmail","Google","Email","Web","envelope","confirmed"),
            R("googlemail","Gmail","Google","Email","Web","envelope","confirmed"),
            R("drive.google","Google Drive","Google","Cloud files & documents","Cloud / CDN","doc","confirmed"),
            R("docs.google","Google Docs","Google","Cloud documents","Web","doc","confirmed"),
            R("play.google","Google Play","Google","App store / updates","Cloud / CDN","bag","confirmed"),
            R("android.clients.google","Google Play Services","Google","Android services & updates","Cloud / CDN","bag","confirmed"),
            R("google-analytics","Google Analytics","Google","Usage tracking / analytics","Ad / tracker","chart.bar","confirmed"),
            R("googletagmanager","Google Tag Manager","Google","Tag / tracking loader","Ad / tracker","chart.bar","confirmed"),
            R("app-measurement","Google Analytics","Google","App usage analytics","Ad / tracker","chart.bar","confirmed"),
            R("doubleclick","Google Ads","Google","Advertising","Ad / tracker","megaphone","confirmed"),
            R("googlesyndication","Google Ads","Google","Advertising","Ad / tracker","megaphone","confirmed"),
            R("googleadservices","Google Ads","Google","Advertising","Ad / tracker","megaphone","confirmed"),
            R("adservice.google","Google Ads","Google","Advertising","Ad / tracker","megaphone","confirmed"),
            R("safebrowsing","Google Safe Browsing","Google","Malware/phishing URL check","Web","checkmark.shield","confirmed"),
            R("maps.google","Google Maps","Google","Maps & navigation","Web","map","confirmed"),
            R("gstatic","Google Assets","Google","App data & static assets","Cloud / CDN","cloud","confirmed"),
            R("googleapis","Google APIs","Google","App backend & API calls","Cloud / CDN","cloud","confirmed"),
            R("googleusercontent","Google Content","Google","User content & images","Cloud / CDN","cloud","confirmed"),
            R("gcp.gvt2","Google Cloud","Google","Cloud backend","Cloud / CDN","cloud","confirmed"),
            // Meta
            R("whatsapp","WhatsApp","Meta","Messaging & calls","Social","message","confirmed"),
            R("cdninstagram","Instagram","Meta","Social media","Social","camera","confirmed"),
            R("instagram","Instagram","Meta","Social media","Social","camera","confirmed"),
            R("fbcdn","Facebook","Meta","Social media content","Social","person.2","confirmed"),
            R("facebook","Facebook","Meta","Social media","Social","person.2","confirmed"),
            R("fbsbx","Facebook","Meta","Social media","Social","person.2","confirmed"),
            R("messenger","Messenger","Meta","Messaging","Social","message","confirmed"),
            R("oculus","Meta Quest","Meta","VR headset services","Web","visionpro","confirmed"),
            // Streaming / media
            R("nflxvideo","Netflix","Netflix","Video streaming","Streaming","play.rectangle","confirmed"),
            R("nflximg","Netflix","Netflix","Video artwork & assets","Streaming","play.rectangle","confirmed"),
            R("netflix","Netflix","Netflix","Video streaming","Streaming","play.rectangle","confirmed"),
            R("spotifycdn","Spotify","Spotify","Music streaming","Music","music.note","confirmed"),
            R("scdn.co","Spotify","Spotify","Music streaming","Music","music.note","confirmed"),
            R("spotify","Spotify","Spotify","Music streaming","Music","music.note","confirmed"),
            R("ttvnw","Twitch","Amazon","Live-stream video","Streaming","play.rectangle","confirmed"),
            R("jtvnw","Twitch","Amazon","Live-stream assets","Streaming","play.rectangle","confirmed"),
            R("twitch","Twitch","Amazon","Live-stream video","Streaming","play.rectangle","confirmed"),
            R("hulustream","Hulu","Disney","Video streaming","Streaming","play.rectangle","confirmed"),
            R("hulu","Hulu","Disney","Video streaming","Streaming","play.rectangle","confirmed"),
            R("dssott","Disney+","Disney","Video streaming","Streaming","play.rectangle","confirmed"),
            R("bamgrid","Disney+","Disney","Video streaming","Streaming","play.rectangle","confirmed"),
            R("disneyplus","Disney+","Disney","Video streaming","Streaming","play.rectangle","confirmed"),
            R("hbomax","Max (HBO)","Warner","Video streaming","Streaming","play.rectangle","confirmed"),
            R("aiv-cdn","Prime Video","Amazon","Video streaming","Streaming","play.rectangle","confirmed"),
            R("aiv-delivery","Prime Video","Amazon","Video streaming","Streaming","play.rectangle","confirmed"),
            R("pandora","Pandora","Pandora","Music streaming","Music","music.note","confirmed"),
            R("soundcloud","SoundCloud","SoundCloud","Music streaming","Music","music.note","confirmed"),
            R("plex.tv","Plex","Plex","Media server","Streaming","play.rectangle","confirmed"),
            R("plex.direct","Plex","Plex","Media server","Streaming","play.rectangle","confirmed"),
            R("jellyfin","Jellyfin","Jellyfin","Media server","Streaming","play.rectangle","confirmed"),
            R("vimeo","Vimeo","Vimeo","Video streaming","Streaming","play.rectangle","confirmed"),
            R("tiktokv","TikTok","ByteDance","Short-video social","Social","play.rectangle","confirmed"),
            R("tiktokcdn","TikTok","ByteDance","Short-video social","Social","play.rectangle","confirmed"),
            R("byteoversea","TikTok","ByteDance","Short-video social","Social","play.rectangle","confirmed"),
            R("muscdn","TikTok","ByteDance","Short-video content","Social","play.rectangle","confirmed"),
            R("tiktok","TikTok","ByteDance","Short-video social","Social","play.rectangle","confirmed"),
            // Social
            R("redditmedia","Reddit","Reddit","Social content","Social","bubble.left.and.bubble.right","confirmed"),
            R("redditstatic","Reddit","Reddit","Social content","Social","bubble.left.and.bubble.right","confirmed"),
            R("reddit","Reddit","Reddit","Social / forums","Social","bubble.left.and.bubble.right","confirmed"),
            R("twimg","X (Twitter)","X","Social media content","Social","bird","confirmed"),
            R("twitter","X (Twitter)","X","Social media","Social","bird","confirmed"),
            R("pinimg","Pinterest","Pinterest","Social media","Social","pin","confirmed"),
            R("pinterest","Pinterest","Pinterest","Social media","Social","pin","confirmed"),
            R("sc-cdn","Snapchat","Snap","Social media","Social","camera","confirmed"),
            R("snapchat","Snapchat","Snap","Social media","Social","camera","confirmed"),
            R("licdn","LinkedIn","Microsoft","Professional network","Social","person.2","confirmed"),
            R("linkedin","LinkedIn","Microsoft","Professional network","Social","person.2","confirmed"),
            // Messaging / meetings
            R("signal.org","Signal","Signal","Private messaging","Social","lock.message","confirmed"),
            R("whispersystems","Signal","Signal","Private messaging","Social","lock.message","confirmed"),
            R("telegram","Telegram","Telegram","Messaging","Social","paperplane","confirmed"),
            R("discord","Discord","Discord","Chat & voice","Social","message","confirmed"),
            R("slack-edge","Slack","Slack","Team chat","Web","message","confirmed"),
            R("slack","Slack","Slack","Team chat","Web","message","confirmed"),
            R("zoom.us","Zoom","Zoom","Video meetings","Streaming","video","confirmed"),
            R("zoomgov","Zoom","Zoom","Video meetings","Streaming","video","confirmed"),
            R("teams.microsoft","Microsoft Teams","Microsoft","Video meetings / chat","Web","video","confirmed"),
            R("meet.google","Google Meet","Google","Video meetings","Streaming","video","confirmed"),
            R("webex","Webex","Cisco","Video meetings","Streaming","video","confirmed"),
            // Microsoft
            R("windowsupdate","Windows Update","Microsoft","OS update download","Cloud / CDN","arrow.down.circle","confirmed"),
            R("delivery.mp.microsoft","Windows Update","Microsoft","OS update delivery","Cloud / CDN","arrow.down.circle","confirmed"),
            R("onedrive","OneDrive","Microsoft","Cloud file sync","Cloud / CDN","arrow.up.arrow.down","confirmed"),
            R("sharepoint","SharePoint","Microsoft","Cloud documents","Web","doc","confirmed"),
            R("outlook","Outlook","Microsoft","Email","Web","envelope","confirmed"),
            R("office","Microsoft 365","Microsoft","Office apps & cloud","Web","doc","confirmed"),
            R("xboxlive","Xbox Live","Microsoft","Gaming service","Web","gamecontroller","confirmed"),
            R("xbox","Xbox","Microsoft","Gaming service","Web","gamecontroller","confirmed"),
            // Amazon / shopping / payments
            R("alexa.amazon","Alexa","Amazon","Voice assistant","IoT telemetry","mic","confirmed"),
            R("avs-alexa","Alexa","Amazon","Voice assistant","IoT telemetry","mic","confirmed"),
            R("kindle","Kindle","Amazon","E-reader service","Web","book","confirmed"),
            R("media-amazon","Amazon","Amazon","Shopping","Web","cart","confirmed"),
            R("ssl-images-amazon","Amazon","Amazon","Shopping","Web","cart","confirmed"),
            R("amazon.com","Amazon","Amazon","Shopping","Web","cart","confirmed"),
            R("ebay","eBay","eBay","Shopping","Web","cart","confirmed"),
            R("paypal","PayPal","PayPal","Payments","Web","creditcard","confirmed"),
            R("stripe.com","Stripe","Stripe","Payments","Web","creditcard","confirmed"),
            // Gaming
            R("steampowered","Steam","Valve","Game platform / downloads","Web","gamecontroller","confirmed"),
            R("steamstatic","Steam","Valve","Game assets","Web","gamecontroller","confirmed"),
            R("steamserver","Steam","Valve","Game servers","Web","gamecontroller","confirmed"),
            R("epicgames","Epic Games","Epic","Gaming platform","Web","gamecontroller","confirmed"),
            R("fortnite","Fortnite","Epic","Online game","Web","gamecontroller","confirmed"),
            R("playstation","PlayStation Network","Sony","Gaming service","Web","gamecontroller","confirmed"),
            R("psn","PlayStation Network","Sony","Gaming service","Web","gamecontroller","confirmed"),
            R("nintendo","Nintendo","Nintendo","Gaming service","Web","gamecontroller","confirmed"),
            R("riotgames","Riot Games","Riot","Online game","Web","gamecontroller","confirmed"),
            R("battle.net","Blizzard","Blizzard","Gaming platform","Web","gamecontroller","confirmed"),
            R("roblox","Roblox","Roblox","Online game","Web","gamecontroller","confirmed"),
            R("rbxcdn","Roblox","Roblox","Game assets","Web","gamecontroller","confirmed"),
            R("minecraft","Minecraft","Mojang","Online game","Web","gamecontroller","confirmed"),
            // Smart home / IoT
            R("dropcam","Nest","Google","Smart camera","IoT telemetry","video","confirmed"),
            R("nest.com","Nest","Google","Smart-home device","IoT telemetry","house","confirmed"),
            R("ring.com","Ring","Amazon","Video doorbell / camera","IoT telemetry","video","confirmed"),
            R("sonos","Sonos","Sonos","Smart speaker","Music","hifispeaker","confirmed"),
            R("tuyaus","Tuya","Tuya","Smart-home device check-in","IoT telemetry","sensor","confirmed"),
            R("tuyaeu","Tuya","Tuya","Smart-home device check-in","IoT telemetry","sensor","confirmed"),
            R("tuya","Tuya","Tuya","Smart-home device check-in","IoT telemetry","sensor","confirmed"),
            R("ecobee","Ecobee","Ecobee","Smart thermostat","IoT telemetry","thermometer","confirmed"),
            R("wyze","Wyze","Wyze","Smart camera","IoT telemetry","video","confirmed"),
            R("tplinkcloud","TP-Link Kasa","TP-Link","Smart-home device","IoT telemetry","sensor","confirmed"),
            R("meethue","Philips Hue","Signify","Smart lights","IoT telemetry","lightbulb","confirmed"),
            R("smartthings","SmartThings","Samsung","Smart-home hub","IoT telemetry","house","confirmed"),
            R("myqdevice","MyQ","Chamberlain","Smart garage","IoT telemetry","house","confirmed"),
            R("govee","Govee","Govee","Smart lights","IoT telemetry","lightbulb","confirmed"),
            R("irobot","iRobot","iRobot","Robot vacuum","IoT telemetry","sensor","confirmed"),
            // Dev / infra / AI
            R("githubusercontent","GitHub","GitHub","Code & content hosting","Web","chevron.left.forwardslash.chevron.right","confirmed"),
            R("github","GitHub","GitHub","Code hosting","Web","chevron.left.forwardslash.chevron.right","confirmed"),
            R("gitlab","GitLab","GitLab","Code hosting","Web","chevron.left.forwardslash.chevron.right","confirmed"),
            R("openai","OpenAI / ChatGPT","OpenAI","AI assistant","Web","brain","confirmed"),
            R("oaistatic","OpenAI / ChatGPT","OpenAI","AI assistant assets","Web","brain","confirmed"),
            R("anthropic","Anthropic / Claude","Anthropic","AI assistant","Web","brain","confirmed"),
            R("claude.ai","Anthropic / Claude","Anthropic","AI assistant","Web","brain","confirmed"),
            R("dropboxusercontent","Dropbox","Dropbox","Cloud file sync","Cloud / CDN","arrow.up.arrow.down","confirmed"),
            R("dropbox","Dropbox","Dropbox","Cloud file sync","Cloud / CDN","arrow.up.arrow.down","confirmed"),
            R("wikipedia","Wikipedia","Wikimedia","Reference","Web","book","confirmed"),
            R("wikimedia","Wikimedia","Wikimedia","Reference","Web","book","confirmed"),
            // Trackers / analytics / ad-tech
            R("crashlytics","Crashlytics","Google","Crash reporting","Ad / tracker","ant","confirmed"),
            R("firebaseio","Firebase","Google","App backend / realtime","Cloud / CDN","flame","confirmed"),
            R("firebase","Firebase","Google","App backend / analytics","Cloud / CDN","flame","confirmed"),
            R("sentry.io","Sentry","Sentry","Error tracking","Ad / tracker","ant","confirmed"),
            R("bugsnag","Bugsnag","Bugsnag","Error tracking","Ad / tracker","ant","confirmed"),
            R("segment.io","Segment","Twilio","Analytics pipeline","Ad / tracker","chart.bar","confirmed"),
            R("segment.com","Segment","Twilio","Analytics pipeline","Ad / tracker","chart.bar","confirmed"),
            R("amplitude","Amplitude","Amplitude","Product analytics","Ad / tracker","chart.bar","confirmed"),
            R("mixpanel","Mixpanel","Mixpanel","Product analytics","Ad / tracker","chart.bar","confirmed"),
            R("branch.io","Branch","Branch","Attribution tracking","Ad / tracker","point.topleft.down.curvedto.point.bottomright.up","confirmed"),
            R("appsflyer","AppsFlyer","AppsFlyer","Ad attribution","Ad / tracker","megaphone","confirmed"),
            R("adjust.com","Adjust","Adjust","Ad attribution","Ad / tracker","megaphone","confirmed"),
            R("scorecardresearch","Comscore","Comscore","Audience tracking","Ad / tracker","chart.bar","confirmed"),
            R("comscore","Comscore","Comscore","Audience tracking","Ad / tracker","chart.bar","confirmed"),
            R("criteo","Criteo","Criteo","Ad retargeting","Ad / tracker","megaphone","confirmed"),
            R("adnxs","Xandr / AppNexus","Microsoft","Advertising exchange","Ad / tracker","megaphone","confirmed"),
            R("pubmatic","PubMatic","PubMatic","Advertising exchange","Ad / tracker","megaphone","confirmed"),
            R("rubiconproject","Magnite","Magnite","Advertising exchange","Ad / tracker","megaphone","confirmed"),
            R("openx","OpenX","OpenX","Advertising exchange","Ad / tracker","megaphone","confirmed"),
            R("taboola","Taboola","Taboola","Content ads","Ad / tracker","megaphone","confirmed"),
            R("outbrain","Outbrain","Outbrain","Content ads","Ad / tracker","megaphone","confirmed"),
            R("applovin","AppLovin","AppLovin","Mobile ads","Ad / tracker","megaphone","confirmed"),
            R("unityads","Unity Ads","Unity","In-game ads","Ad / tracker","megaphone","confirmed"),
            R("onetrust","OneTrust","OneTrust","Cookie consent","Ad / tracker","checkmark.shield","confirmed"),
            R("cookielaw","OneTrust","OneTrust","Cookie consent","Ad / tracker","checkmark.shield","confirmed"),
            // Time / connectivity
            R("time.apple","Apple Time","Apple","Clock sync (NTP)","DNS / system","clock","confirmed"),
            R("pool.ntp","NTP Time","NTP Pool","Clock sync (NTP)","DNS / system","clock","confirmed"),
            R("time.google","Google Time","Google","Clock sync (NTP)","DNS / system","clock","confirmed"),
            R("jsdelivr","jsDelivr CDN","jsDelivr","Website code libraries","Cloud / CDN","curlybraces","confirmed"),
            R("cdnjs","cdnjs","Cloudflare","Website code libraries","Cloud / CDN","curlybraces","confirmed"),
            R("unpkg","unpkg CDN","unpkg","Website code libraries","Cloud / CDN","curlybraces","confirmed"),
            // Generic CDNs / cloud — app can't be confirmed from the network alone
            R("cloudfront","Amazon CloudFront","Amazon","Shared CDN — hosted app can't be confirmed","Cloud / CDN","cloud","generic"),
            R("amazonaws","Amazon AWS","Amazon","Cloud hosting — hosted app can't be confirmed","Cloud / CDN","cloud","generic"),
            R("akamaihd","Akamai","Akamai","Shared CDN — hosted app can't be confirmed","Cloud / CDN","cloud","generic"),
            R("akamaized","Akamai","Akamai","Shared CDN — hosted app can't be confirmed","Cloud / CDN","cloud","generic"),
            R("akamai","Akamai","Akamai","Shared CDN — hosted app can't be confirmed","Cloud / CDN","cloud","generic"),
            R("fastly","Fastly","Fastly","Shared CDN — hosted app can't be confirmed","Cloud / CDN","cloud","generic"),
            R("cloudflare","Cloudflare","Cloudflare","Shared CDN — hosted app can't be confirmed","Cloud / CDN","cloud","generic"),
        ]
        loadUserRules()
    }
    private func loadUserRules() {
        let path = NetPaths.dir + "/service-fingerprints.txt"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        var extra: [Rule] = []
        for raw in content.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let p = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard p.count >= 2 else { continue }
            extra.append(Rule(pat: p[0].lowercased(), name: p[1],
                              vendor: p.count > 2 ? p[2] : "",
                              purpose: p.count > 3 ? p[3] : "",
                              category: p.count > 4 ? p[4] : "Web",
                              icon: p.count > 5 ? p[5] : "app.dashed", conf: "confirmed"))
        }
        rules = extra + rules
    }
    func match(host: String, org: String, port: Int) -> ServiceHit? {
        let h = host.lowercased()
        if h.contains(".") && h.contains(where: { $0.isLetter }) {
            for rr in rules where h.contains(rr.pat) {
                return ServiceHit(name: rr.name, vendor: rr.vendor, purpose: rr.purpose, category: rr.category, icon: rr.icon, confidence: rr.conf)
            }
        }
        return orgFallback(org)
    }
    private func orgFallback(_ org: String) -> ServiceHit? {
        switch org {
        case "Netflix": return ServiceHit(name: "Netflix", vendor: "Netflix", purpose: "Video streaming", category: "Streaming", icon: "play.rectangle", confidence: "likely")
        case "Meta": return ServiceHit(name: "Facebook / Instagram / WhatsApp", vendor: "Meta", purpose: "Social media", category: "Social", icon: "person.2", confidence: "likely")
        case "GitHub": return ServiceHit(name: "GitHub", vendor: "GitHub", purpose: "Code hosting", category: "Web", icon: "chevron.left.forwardslash.chevron.right", confidence: "likely")
        case "Apple": return ServiceHit(name: "Apple services", vendor: "Apple", purpose: "Apple / iCloud services", category: "Apple / system", icon: "apple.logo", confidence: "likely")
        case "Akamai","Cloudflare","Fastly","Amazon CloudFront","Amazon AWS","Microsoft Azure","Microsoft","Google Cloud","OpenDNS / Cisco","Quad9":
            return ServiceHit(name: org, vendor: org, purpose: "Shared hosting / CDN — the specific app can't be confirmed from the network alone", category: "Cloud / CDN", icon: "cloud", confidence: "generic")
        default: return nil
        }
    }
}
