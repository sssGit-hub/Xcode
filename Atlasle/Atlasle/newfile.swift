// AtlasleApp.swift
// Native SwiftUI Atlasle — Daily + Unlimited modes, practice/ranked, difficulty,
// streaks, continent mastery, a hand-drawn world map, haptics, sound, iCloud sync.
//
// SETUP:
// 1. New iOS App project (SwiftUI), iOS 16.0+
// 2. DELETE the auto-generated @main file and ContentView.swift
// 3. Add this file
// 4. Add your logo to Assets.xcassets named "atlasle_logo"
// 5. Enable iCloud: Target > Signing & Capabilities > + Capability > iCloud
//    then check "Key-value storage". Requires Apple Developer account.
// 6. Build & run

import SwiftUI
import Combine
import AudioToolbox

// MARK: - App Entry Point

@main
struct AtlasleApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.light)
        }
    }
}

// MARK: - Models

struct Country: Identifiable, Equatable, Codable {
    var id: String { code }
    let name: String
    let code: String
    let flag: String
    let continent: String
    let area: Double          // thousands of sq miles
    let gdp: Double           // billions USD
    let language: String
    let population: Double     // millions
    let government: String
    let colors: [String]
    let famous: Bool           // included in "Easy" difficulty
    let lat: Double            // map latitude
    let lon: Double            // map longitude

    static func == (l: Country, r: Country) -> Bool { l.code == r.code }
}

enum GameMode: String, Codable { case daily, unlimited }
enum Difficulty: String, Codable, CaseIterable { case easy, world
    var label: String { self == .easy ? "Easy" : "World" }
    var blurb: String { self == .easy ? "~70 well-known countries" : "All 195 countries" }
}

struct GameRecord: Identifiable, Codable {
    let id: String
    let countryCode: String
    let countryName: String
    let countryFlag: String
    let continent: String
    let guesses: Int           // 1...8 for wins, -1 for fail
    let date: Date
    let won: Bool
    let mode: GameMode
    let ranked: Bool
    let difficulty: Difficulty
}

enum ClueAccuracy { case exact, close, far }

struct ClueResult {
    let label: String
    let value: String
    let subtitle: String
    let accuracy: ClueAccuracy
}

struct GuessResult: Identifiable {
    let id = UUID()
    let country: Country
    let clues: [ClueResult]
    let isCorrect: Bool
}

// MARK: - Settings Store

class Settings: ObservableObject {
    @Published var soundOn: Bool {
        didSet { UserDefaults.standard.set(soundOn, forKey: "atlasle_sound") }
    }
    @Published var hapticsOn: Bool {
        didSet { UserDefaults.standard.set(hapticsOn, forKey: "atlasle_haptics") }
    }
    @Published var hasOnboarded: Bool {
        didSet { UserDefaults.standard.set(hasOnboarded, forKey: "atlasle_onboarded") }
    }

    init() {
        let d = UserDefaults.standard
        soundOn = d.object(forKey: "atlasle_sound") as? Bool ?? true
        hapticsOn = d.object(forKey: "atlasle_haptics") as? Bool ?? true
        hasOnboarded = d.bool(forKey: "atlasle_onboarded")
    }
}

// MARK: - Data Manager (history, stats, streak, iCloud sync)

class AppDataManager: ObservableObject {
    @Published var gameHistory: [GameRecord] = []

    private let historyKey = "atlasle_game_history"
    private let cloud = NSUbiquitousKeyValueStore.default

    init() {
        loadHistory()
        // Pull from iCloud if it has more data, and listen for remote changes.
        NotificationCenter.default.addObserver(
            self, selector: #selector(cloudChanged(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud)
        cloud.synchronize()
        mergeCloud()
    }

    @objc private func cloudChanged(_ note: Notification) {
        DispatchQueue.main.async { self.mergeCloud() }
    }

    private func decode(_ data: Data?) -> [GameRecord] {
        guard let data, let recs = try? JSONDecoder().decode([GameRecord].self, from: data)
        else { return [] }
        return recs
    }

    private func loadHistory() {
        gameHistory = decode(UserDefaults.standard.data(forKey: historyKey))
    }

    private func mergeCloud() {
        let cloudRecs = decode(cloud.data(forKey: historyKey))
        guard !cloudRecs.isEmpty else { return }
        // Merge by id, keep union, newest first.
        var byID = [String: GameRecord]()
        for r in gameHistory { byID[r.id] = r }
        for r in cloudRecs { byID[r.id] = r }
        let merged = byID.values.sorted { $0.date > $1.date }
        if merged.count != gameHistory.count {
            gameHistory = merged
            persistLocalOnly()
        }
    }

    func saveGame(country: Country, guesses: Int, won: Bool,
                  mode: GameMode, ranked: Bool, difficulty: Difficulty) {
        let rec = GameRecord(
            id: UUID().uuidString, countryCode: country.code,
            countryName: country.name, countryFlag: country.flag,
            continent: country.continent, guesses: guesses,
            date: Date(), won: won, mode: mode, ranked: ranked, difficulty: difficulty)
        gameHistory.insert(rec, at: 0)
        persist()
    }

    private func persistLocalOnly() {
        if let enc = try? JSONEncoder().encode(gameHistory) {
            UserDefaults.standard.set(enc, forKey: historyKey)
        }
    }

    private func persist() {
        if let enc = try? JSONEncoder().encode(gameHistory) {
            UserDefaults.standard.set(enc, forKey: historyKey)
            cloud.set(enc, forKey: historyKey)
            cloud.synchronize()
        }
    }

    func clearHistory() {
        gameHistory = []
        UserDefaults.standard.removeObject(forKey: historyKey)
        cloud.removeObject(forKey: historyKey)
        cloud.synchronize()
    }

    // Only ranked games count toward stats.
    var rankedGames: [GameRecord] { gameHistory.filter { $0.ranked } }

    var stats: GameStats {
        let ranked = rankedGames
        let total = ranked.count
        let wins = ranked.filter { $0.won }.count
        let avg = wins > 0
            ? Double(ranked.filter { $0.won }.map { $0.guesses }.reduce(0, +)) / Double(wins)
            : 0
        var dist = [Int: Int]()
        for i in 1...8 { dist[i] = ranked.filter { $0.won && $0.guesses == i }.count }
        dist[-1] = ranked.filter { !$0.won }.count
        return GameStats(totalGames: total, wins: wins, losses: total - wins,
                         averageGuesses: avg, distribution: dist)
    }

    // Win counts include ALL games (practice + ranked) for the trophy room.
    func winCount(_ code: String) -> Int {
        gameHistory.filter { $0.won && $0.countryCode == code }.count
    }
    func hasWon(_ code: String) -> Bool { winCount(code) > 0 }

    func continentMastery(_ all: [Country]) -> [(continent: String, found: Int, total: Int)] {
        let order = ["Africa","Asia","Europe","North America","South America","Oceania"]
        let foundCodes = Set(gameHistory.filter { $0.won }.map { $0.countryCode })
        return order.map { cont in
            let inCont = all.filter { $0.continent == cont }
            let found = inCont.filter { foundCodes.contains($0.code) }.count
            return (cont, found, inCont.count)
        }
    }

    // MARK: Daily completion + streak

    static func dayKey(_ date: Date = Date()) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        return f.string(from: date)
    }

    func dailyRecord(for date: Date = Date()) -> GameRecord? {
        let key = AppDataManager.dayKey(date)
        return gameHistory.first { $0.mode == .daily && AppDataManager.dayKey($0.date) == key }
    }

    var todayCompleted: Bool { dailyRecord() != nil }
    var todayWon: Bool { dailyRecord()?.won ?? false }

    /// Current streak: consecutive days (ending today or yesterday) the daily was WON.
    var currentStreak: Int {
        let cal = Calendar.current
        let dailyWins = gameHistory.filter { $0.mode == .daily && $0.won }
        guard !dailyWins.isEmpty else { return 0 }
        let wonDays = Set(dailyWins.map { AppDataManager.dayKey($0.date) })
        // Start from today; if today not done yet, allow streak ending yesterday.
        var cursor = Date()
        if !wonDays.contains(AppDataManager.dayKey(cursor)) {
            cursor = cal.date(byAdding: .day, value: -1, to: cursor)!
            if !wonDays.contains(AppDataManager.dayKey(cursor)) { return 0 }
        }
        var streak = 0
        while wonDays.contains(AppDataManager.dayKey(cursor)) {
            streak += 1
            cursor = cal.date(byAdding: .day, value: -1, to: cursor)!
        }
        return streak
    }

    var bestStreak: Int {
        let cal = Calendar.current
        let wonDays = gameHistory.filter { $0.mode == .daily && $0.won }
            .map { AppDataManager.dayKey($0.date) }
        let unique = Array(Set(wonDays)).sorted()
        guard !unique.isEmpty else { return 0 }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        let dates = unique.compactMap { f.date(from: $0) }
        var best = 1, run = 1
        for i in 1..<dates.count {
            if let prev = cal.date(byAdding: .day, value: 1, to: dates[i-1]),
               cal.isDate(prev, inSameDayAs: dates[i]) {
                run += 1; best = max(best, run)
            } else { run = 1 }
        }
        return best
    }
}

struct GameStats {
    let totalGames: Int
    let wins: Int
    let losses: Int
    let averageGuesses: Double
    let distribution: [Int: Int]
    var winRate: Double { totalGames > 0 ? Double(wins)/Double(totalGames)*100 : 0 }
}

// MARK: - Haptics & Sound


enum FX {
    static func tap(_ on: Bool) {
        guard on else { return }
        let g = UIImpactFeedbackGenerator(style: .light); g.impactOccurred()
    }
    static func success(_ on: Bool) {
        guard on else { return }
        let g = UINotificationFeedbackGenerator(); g.notificationOccurred(.success)
    }
    static func failure(_ on: Bool) {
        guard on else { return }
        let g = UINotificationFeedbackGenerator(); g.notificationOccurred(.warning)
    }
    static func sound(_ id: SystemSoundID, _ on: Bool) {
        guard on else { return }
        AudioServicesPlaySystemSound(id)
    }
}

// MARK: - Logo
// Requires "atlasle_logo" in Assets.xcassets

struct LogoView: View {
    var size: CGFloat = 96
    var body: some View {
        Image("atlasle_logo")
            .resizable().scaledToFit()
            .frame(width: size, height: size)
    }
}

// MARK: - Theme (derived from logo palette)

struct Theme {
    static let paper     = Color(red: 0.992, green: 0.914, blue: 0.816)
    static let paperDark = Color(red: 0.965, green: 0.859, blue: 0.737)
    static let ink       = Color(red: 0.153, green: 0.110, blue: 0.082)
    static let inkSoft   = Color(red: 0.420, green: 0.333, blue: 0.267)
    static let line      = Color(red: 0.863, green: 0.792, blue: 0.722)

    static let green   = Color(red: 0.125, green: 0.686, blue: 0.569) // teal
    static let greenBg = Color(red: 0.804, green: 0.933, blue: 0.906)
    static let amber   = Color(red: 0.855, green: 0.616, blue: 0.188) // gold
    static let amberBg = Color(red: 0.980, green: 0.906, blue: 0.773)
    static let red     = Color(red: 0.941, green: 0.510, blue: 0.471) // coral
    static let redBg   = Color(red: 0.988, green: 0.863, blue: 0.851)

    // Continent colors for the map (warm, on-theme)
    static func continentColor(_ c: String) -> Color {
        switch c {
        case "Africa":        return Color(red: 0.855, green: 0.616, blue: 0.188)
        case "Asia":          return Color(red: 0.941, green: 0.510, blue: 0.471)
        case "Europe":        return Color(red: 0.125, green: 0.686, blue: 0.569)
        case "North America": return Color(red: 0.357, green: 0.553, blue: 0.741)
        case "South America": return Color(red: 0.776, green: 0.451, blue: 0.667)
        case "Oceania":       return Color(red: 0.553, green: 0.624, blue: 0.275)
        default:              return Theme.inkSoft
        }
    }

    static func bg(for a: ClueAccuracy) -> Color {
        switch a { case .exact: return greenBg; case .close: return amberBg; case .far: return redBg }
    }
    static func fg(for a: ClueAccuracy) -> Color {
        switch a { case .exact: return green; case .close: return amber; case .far: return red }
    }
}

// MARK: - Game ViewModel

class GameViewModel: ObservableObject {
    @Published var secret: Country
    @Published var guesses: [GuessResult] = []
    @Published var searchText = ""
    @Published var errorMessage = ""
    @Published var gameOver = false
    @Published var won = false
    @Published var showFlagOverlay = false
    @Published var overlayFlag = ""
    @Published var overlayName = ""
    @Published var showInfo = false

    let maxGuesses = 8
    var mode: GameMode = .unlimited
    var ranked: Bool = true
    var difficulty: Difficulty = .world

    static let everything = GameViewModel.allCountries()

    var pool: [Country] {
        difficulty == .easy ? Self.everything.filter { $0.famous } : Self.everything
    }
    // Autocomplete & guessing always allow any country (so easy mode isn't a giveaway).
    let countries = GameViewModel.everything

    var filteredCountries: [Country] {
        let q = searchText.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return countries.filter {
            $0.name.lowercased().contains(q) || $0.code.lowercased().contains(q)
        }.prefix(6).map { $0 }
    }

    var guessNumber: Int { min(guesses.count + 1, maxGuesses) }

    init() {
        self.secret = GameViewModel.everything.randomElement()!
    }

    /// Deterministic daily pick seeded by date (same for everyone, from full world list).
    static func dailyCountry(for date: Date = Date()) -> Country {
        let key = AppDataManager.dayKey(date)
        var hash = 5381
        for b in key.utf8 { hash = ((hash << 5) &+ hash) &+ Int(b) }
        let all = everything
        let idx = abs(hash) % all.count
        return all[idx]
    }

    func startDaily() {
        mode = .daily; ranked = true; difficulty = .world
        secret = GameViewModel.dailyCountry()
        resetBoard()
    }

    func startUnlimited(ranked: Bool, difficulty: Difficulty) {
        mode = .unlimited; self.ranked = ranked; self.difficulty = difficulty
        secret = pool.randomElement()!
        resetBoard()
    }

    func newGameSameSettings() {
        if mode == .daily { startDaily() }
        else { secret = pool.randomElement()!; resetBoard() }
    }

    private func resetBoard() {
        guesses = []; searchText = ""; errorMessage = ""
        gameOver = false; won = false; showInfo = false
    }

    func submitGuess(soundOn: Bool, hapticsOn: Bool) {
        guard !gameOver else { return }
        let raw = searchText.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { errorMessage = "Type a country first."; return }
        guard let country = findCountry(raw) else {
            errorMessage = "\"\(raw)\" isn't in the country list."; return
        }
        errorMessage = ""; searchText = ""
        let clues = evaluate(guess: country)
        let correct = country == secret
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            guesses.insert(GuessResult(country: country, clues: clues, isCorrect: correct), at: 0)
        }
        if correct {
            won = true; gameOver = true
            FX.success(hapticsOn); FX.sound(1025, soundOn)
        } else if guesses.count >= maxGuesses {
            won = false; gameOver = true
            FX.failure(hapticsOn); FX.sound(1053, soundOn)
        } else {
            FX.tap(hapticsOn); FX.sound(1104, soundOn)
        }
    }

    func giveUp() { guard !gameOver else { return }; won = false; gameOver = true }

    func showFlag(emoji: String, name: String) {
        overlayFlag = emoji; overlayName = name
        withAnimation(.easeOut(duration: 0.15)) { showFlagOverlay = true }
    }

    func evaluate(guess g: Country) -> [ClueResult] {
        var clues: [ClueResult] = []
        clues.append(ClueResult(label: "Continent", value: g.continent, subtitle: "",
                                accuracy: g.continent == secret.continent ? .exact : .far))
        let gl = String(g.name.prefix(1)).uppercased()
        let sl = String(secret.name.prefix(1)).uppercased()
        clues.append(ClueResult(label: "Letter", value: gl, subtitle: gl == sl ? "match" : "",
                                accuracy: gl == sl ? .exact : .far))
        let dA = secret.area - g.area
        if abs(dA) < 0.001 { clues.append(ClueResult(label: "Size", value: "exact", subtitle: "", accuracy: .exact)) }
        else {
            let ratio = abs(dA) / max(g.area, 0.001)
            clues.append(ClueResult(label: "Size", value: Self.fmtAreaDiff(dA) + " mi² off",
                subtitle: dA > 0 ? "↑ bigger" : "↓ smaller", accuracy: ratio <= 0.25 ? .close : .far))
        }
        let dP = secret.population - g.population
        if abs(dP) < 0.001 { clues.append(ClueResult(label: "Population", value: "exact", subtitle: "", accuracy: .exact)) }
        else {
            let ratio = abs(dP) / max(g.population, 0.001)
            clues.append(ClueResult(label: "Population", value: Self.fmtPopDiff(dP) + " off",
                subtitle: dP > 0 ? "↑ more" : "↓ fewer", accuracy: ratio <= 0.25 ? .close : .far))
        }
        let dG = secret.gdp - g.gdp
        if dG == 0 { clues.append(ClueResult(label: "Economy", value: "exact", subtitle: "", accuracy: .exact)) }
        else {
            let ratio = abs(dG) / max(g.gdp, 0.001)
            clues.append(ClueResult(label: "Economy", value: Self.fmtGdpDiff(dG) + " off",
                subtitle: dG > 0 ? "↑ richer" : "↓ poorer", accuracy: ratio <= 0.25 ? .close : .far))
        }
        clues.append(ClueResult(label: "Government", value: g.government, subtitle: "",
                                accuracy: g.government == secret.government ? .exact : .far))
        clues.append(ClueResult(label: "Language", value: g.language, subtitle: "",
                                accuracy: g.language == secret.language ? .exact : .far))
        let shared = secret.colors.filter { g.colors.contains($0) }.count
        let pct = Int(round(Double(shared) / Double(secret.colors.count) * 100))
        let acc: ClueAccuracy = pct == 100 ? .exact : pct >= 50 ? .close : .far
        clues.append(ClueResult(label: "Flag", value: "\(pct)%", subtitle: "\(shared) of \(secret.colors.count)", accuracy: acc))
        return clues
    }

    func findCountry(_ raw: String) -> Country? {
        let q = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if let c = countries.first(where: { $0.name.lowercased() == q }) { return c }
        if let c = countries.first(where: { $0.code.lowercased() == q }) { return c }
        let aliases: [String:String] = [
            "usa":"United States","us":"United States","america":"United States",
            "uk":"United Kingdom","britain":"United Kingdom","uae":"United Arab Emirates",
            "korea":"South Korea","drc":"Democratic Republic of the Congo",
            "congo":"Republic of the Congo","czechia":"Czech Republic",
            "timor":"East Timor","burma":"Myanmar"]
        if let m = aliases[q], let c = countries.first(where: { $0.name == m }) { return c }
        return countries.first(where: { $0.name.lowercased().hasPrefix(q) })
    }

    static func fmtAreaDiff(_ d: Double) -> String {
        let s = abs(d)*1000
        if s >= 1_000_000 { return String(format:"%.1fM", s/1_000_000) }
        if s >= 1000 { return "\(Int(round(s/1000)))k" }
        return "\(Int(round(s)))"
    }
    static func fmtGdpDiff(_ d: Double) -> String {
        let b = abs(d)
        if b >= 1000 { return String(format:"$%.1fT", b/1000) }
        if b >= 1 { return "$\(Int(round(b)))B" }
        if b >= 0.001 { return "$\(Int(round(b*1000)))M" }
        return "<$1M"
    }
    static func fmtPopDiff(_ d: Double) -> String {
        let m = abs(d)
        if m >= 1000 { return String(format:"%.2gB", m/1000) }
        if m >= 1 { return "\(Int(round(m)))M" }
        return "\(Int(round(m*1000)))k"
    }
    static func fmtArea(_ t: Double) -> String {
        let s = t*1000
        if s >= 1_000_000 { return String(format:"%.1fM", s/1_000_000) }
        let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0
        let r = max(1, Int(round(s)))
        return f.string(from: NSNumber(value: r)) ?? "\(r)"
    }
    static func fmtPop(_ m: Double) -> String {
        if m >= 1000 { return String(format:"%.2gB", m/1000) }
        if m >= 1 { return m.truncatingRemainder(dividingBy:1) == 0 ? "\(Int(m))M" : String(format:"%.1fM", m) }
        return "\(max(1,Int(round(m*1000))))k"
    }
    static func fmtGdp(_ b: Double) -> String {
        if b >= 1000 { return String(format:"$%.1fT", b/1000) }
        return "$\(b)B"
    }

    static func allCountries() -> [Country] {
        return [
            Country(name:"Afghanistan",code:"AFG",flag:"🇦🇫",continent:"Asia",area:251.827,gdp:19.66,language:"Persian",population:45.0,government:"Theocracy",colors:["white","black","red","green"],famous:true,lat:33.9,lon:67.7),
            Country(name:"Albania",code:"ALB",flag:"🇦🇱",continent:"Europe",area:11.1,gdp:33.33,language:"Albanian",population:2.8,government:"Republic",colors:["red","black"],famous:false,lat:41.2,lon:20.2),
            Country(name:"Algeria",code:"DZA",flag:"🇩🇿",continent:"Africa",area:919.595,gdp:317.17,language:"Arabic",population:48.0,government:"Republic",colors:["green","white","red"],famous:true,lat:28.0,lon:1.7),
            Country(name:"Andorra",code:"AND",flag:"🇦🇩",continent:"Europe",area:0.181,gdp:4.88,language:"Catalan",population:0.084,government:"Const. monarchy",colors:["blue","yellow","red"],famous:false,lat:42.5,lon:1.5),
            Country(name:"Angola",code:"AGO",flag:"🇦🇴",continent:"Africa",area:481.353,gdp:152.35,language:"Portuguese",population:40.2,government:"Republic",colors:["red","black","yellow"],famous:false,lat:-11.2,lon:17.9),
            Country(name:"Antigua and Barbuda",code:"ATG",flag:"🇦🇬",continent:"North America",area:0.171,gdp:2.38,language:"English",population:0.095,government:"Const. monarchy",colors:["red","white","blue","black","yellow"],famous:false,lat:17.1,lon:-61.8),
            Country(name:"Argentina",code:"ARG",flag:"🇦🇷",continent:"South America",area:1073.518,gdp:688.38,language:"Spanish",population:46.0,government:"Republic",colors:["blue","white","yellow","brown"],famous:true,lat:-38.4,lon:-63.6),
            Country(name:"Armenia",code:"ARM",flag:"🇦🇲",continent:"Asia",area:11.484,gdp:31.87,language:"Armenian",population:2.9,government:"Republic",colors:["red","blue","yellow"],famous:false,lat:40.1,lon:45.0),
            Country(name:"Australia",code:"AUS",flag:"🇦🇺",continent:"Oceania",area:2969.906,gdp:2123.96,language:"English",population:27.2,government:"Const. monarchy",colors:["blue","white","red"],famous:true,lat:-25.3,lon:133.8),
            Country(name:"Austria",code:"AUT",flag:"🇦🇹",continent:"Europe",area:32.383,gdp:623.72,language:"German",population:9.1,government:"Republic",colors:["red","white"],famous:true,lat:47.5,lon:14.6),
            Country(name:"Azerbaijan",code:"AZE",flag:"🇦🇿",continent:"Asia",area:33.436,gdp:78.37,language:"Azerbaijani",population:10.5,government:"Republic",colors:["blue","red","green","white"],famous:false,lat:40.1,lon:47.6),
            Country(name:"Bahamas",code:"BHS",flag:"🇧🇸",continent:"North America",area:5.383,gdp:17.04,language:"English",population:0.4,government:"Const. monarchy",colors:["black","yellow","blue"],famous:false,lat:25.0,lon:-77.4),
            Country(name:"Bahrain",code:"BHR",flag:"🇧🇭",continent:"Asia",area:0.295,gdp:48.85,language:"Arabic",population:1.7,government:"Const. monarchy",colors:["white","red"],famous:false,lat:26.0,lon:50.6),
            Country(name:"Bangladesh",code:"BGD",flag:"🇧🇩",continent:"Asia",area:56.977,gdp:510.7,language:"Bengali",population:177.8,government:"Republic",colors:["green","red"],famous:true,lat:23.7,lon:90.4),
            Country(name:"Barbados",code:"BRB",flag:"🇧🇧",continent:"North America",area:0.166,gdp:8.48,language:"English",population:0.28,government:"Republic",colors:["blue","yellow","black"],famous:false,lat:13.2,lon:-59.5),
            Country(name:"Belarus",code:"BLR",flag:"🇧🇾",continent:"Europe",area:80.155,gdp:102.04,language:"Russian",population:8.9,government:"Republic",colors:["red","green","white"],famous:false,lat:53.7,lon:27.9),
            Country(name:"Belgium",code:"BEL",flag:"🇧🇪",continent:"Europe",area:11.787,gdp:776.73,language:"Dutch",population:11.8,government:"Const. monarchy",colors:["black","yellow","red"],famous:true,lat:50.5,lon:4.5),
            Country(name:"Belize",code:"BLZ",flag:"🇧🇿",continent:"North America",area:8.867,gdp:3.45,language:"English",population:0.4,government:"Const. monarchy",colors:["blue","red","white","green","brown"],famous:false,lat:17.2,lon:-88.5),
            Country(name:"Benin",code:"BEN",flag:"🇧🇯",continent:"Africa",area:43.484,gdp:27.79,language:"French",population:15.17,government:"Republic",colors:["green","yellow","red"],famous:false,lat:9.3,lon:2.3),
            Country(name:"Bhutan",code:"BTN",flag:"🇧🇹",continent:"Asia",area:14.824,gdp:3.86,language:"Dzongkha",population:0.8,government:"Const. monarchy",colors:["yellow","orange","white","red"],famous:false,lat:27.5,lon:90.4),
            Country(name:"Bolivia",code:"BOL",flag:"🇧🇴",continent:"South America",area:424.164,gdp:80.74,language:"Spanish",population:12.7,government:"Republic",colors:["red","yellow","green","brown"],famous:false,lat:-16.3,lon:-63.6),
            Country(name:"Bosnia and Herzegovina",code:"BIH",flag:"🇧🇦",continent:"Europe",area:19.772,gdp:36.77,language:"Bosnian",population:3.1,government:"Republic",colors:["blue","yellow","white"],famous:false,lat:43.9,lon:17.7),
            Country(name:"Botswana",code:"BWA",flag:"🇧🇼",continent:"Africa",area:224.711,gdp:21.94,language:"English",population:2.6,government:"Republic",colors:["blue","white","black"],famous:false,lat:-22.3,lon:24.7),
            Country(name:"Brazil",code:"BRA",flag:"🇧🇷",continent:"South America",area:3287.955,gdp:2635.91,language:"Portuguese",population:213.6,government:"Republic",colors:["green","yellow","blue","white"],famous:true,lat:-14.2,lon:-51.9),
            Country(name:"Brunei",code:"BRN",flag:"🇧🇳",continent:"Asia",area:2.226,gdp:16.86,language:"Malay",population:0.5,government:"Absolute monarchy",colors:["yellow","white","black","red"],famous:false,lat:4.5,lon:114.7),
            Country(name:"Bulgaria",code:"BGR",flag:"🇧🇬",continent:"Europe",area:42.811,gdp:148.12,language:"Bulgarian",population:6.7,government:"Republic",colors:["white","green","red"],famous:false,lat:42.7,lon:25.5),
            Country(name:"Burkina Faso",code:"BFA",flag:"🇧🇫",continent:"Africa",area:105.393,gdp:32.51,language:"French",population:24.6,government:"Republic",colors:["red","green","yellow"],famous:false,lat:12.2,lon:-1.6),
            Country(name:"Burundi",code:"BDI",flag:"🇧🇮",continent:"Africa",area:10.747,gdp:8.14,language:"Kirundi",population:14.73,government:"Republic",colors:["red","white","green"],famous:false,lat:-3.4,lon:29.9),
            Country(name:"Cambodia",code:"KHM",flag:"🇰🇭",continent:"Asia",area:69.898,gdp:52.38,language:"Khmer",population:18.1,government:"Const. monarchy",colors:["red","blue","white"],famous:false,lat:12.6,lon:104.9),
            Country(name:"Cameroon",code:"CMR",flag:"🇨🇲",continent:"Africa",area:183.569,gdp:65.14,language:"French",population:30.6,government:"Republic",colors:["green","red","yellow"],famous:false,lat:7.4,lon:12.4),
            Country(name:"Canada",code:"CAN",flag:"🇨🇦",continent:"North America",area:3855.101,gdp:2507.34,language:"English",population:40.5,government:"Const. monarchy",colors:["red","white"],famous:true,lat:56.1,lon:-106.3),
            Country(name:"Cape Verde",code:"CPV",flag:"🇨🇻",continent:"Africa",area:1.557,gdp:3.45,language:"Portuguese",population:0.5,government:"Republic",colors:["blue","white","red","yellow"],famous:false,lat:16.0,lon:-24.0),
            Country(name:"Central African Republic",code:"CAF",flag:"🇨🇫",continent:"Africa",area:240.535,gdp:3.49,language:"French",population:5.7,government:"Republic",colors:["blue","white","green","yellow","red"],famous:false,lat:6.6,lon:20.9),
            Country(name:"Chad",code:"TCD",flag:"🇹🇩",continent:"Africa",area:495.755,gdp:25.63,language:"French",population:21.6,government:"Republic",colors:["blue","yellow","red"],famous:false,lat:15.5,lon:18.7),
            Country(name:"Chile",code:"CHL",flag:"🇨🇱",continent:"South America",area:291.932,gdp:407.85,language:"Spanish",population:19.9,government:"Republic",colors:["red","white","blue"],famous:true,lat:-35.7,lon:-71.5),
            Country(name:"China",code:"CHN",flag:"🇨🇳",continent:"Asia",area:3747.877,gdp:20851.59,language:"Mandarin",population:1412.9,government:"One-party state",colors:["red","yellow"],famous:true,lat:35.9,lon:104.2),
            Country(name:"Colombia",code:"COL",flag:"🇨🇴",continent:"South America",area:440.831,gdp:539.53,language:"Spanish",population:53.9,government:"Republic",colors:["yellow","blue","red"],famous:true,lat:4.6,lon:-74.3),
            Country(name:"Comoros",code:"COM",flag:"🇰🇲",continent:"Africa",area:0.719,gdp:1.81,language:"Comorian",population:0.9,government:"Republic",colors:["yellow","white","red","blue","green"],famous:false,lat:-11.6,lon:43.3),
            Country(name:"Costa Rica",code:"CRI",flag:"🇨🇷",continent:"North America",area:19.73,gdp:109.93,language:"Spanish",population:5.2,government:"Republic",colors:["blue","white","red","yellow","green"],famous:false,lat:9.7,lon:-83.8),
            Country(name:"Croatia",code:"HRV",flag:"🇭🇷",continent:"Europe",area:21.851,gdp:116.57,language:"Croatian",population:3.8,government:"Republic",colors:["red","white","blue","yellow"],famous:true,lat:45.1,lon:15.2),
            Country(name:"Cuba",code:"CUB",flag:"🇨🇺",continent:"North America",area:42.426,gdp:201.99,language:"Spanish",population:10.9,government:"One-party state",colors:["blue","white","red"],famous:true,lat:21.5,lon:-77.8),
            Country(name:"Cyprus",code:"CYP",flag:"🇨🇾",continent:"Asia",area:3.572,gdp:45.17,language:"Greek",population:1.4,government:"Republic",colors:["white","yellow","green"],famous:false,lat:35.1,lon:33.4),
            Country(name:"Czech Republic",code:"CZE",flag:"🇨🇿",continent:"Europe",area:30.45,gdp:432.6,language:"Czech",population:10.53,government:"Republic",colors:["white","red","blue"],famous:true,lat:49.8,lon:15.5),
            Country(name:"Democratic Republic of the Congo",code:"COD",flag:"🇨🇩",continent:"Africa",area:905.354,gdp:123.41,language:"French",population:116.5,government:"Republic",colors:["blue","yellow","red"],famous:false,lat:-4.0,lon:21.8),
            Country(name:"Denmark",code:"DNK",flag:"🇩🇰",continent:"Europe",area:16.639,gdp:503.77,language:"Danish",population:6.0,government:"Const. monarchy",colors:["red","white"],famous:true,lat:56.3,lon:9.5),
            Country(name:"Djibouti",code:"DJI",flag:"🇩🇯",continent:"Africa",area:8.958,gdp:4.72,language:"Arabic",population:1.2,government:"Republic",colors:["white","blue","green","red"],famous:false,lat:11.8,lon:42.6),
            Country(name:"Dominica",code:"DMA",flag:"🇩🇲",continent:"North America",area:0.29,gdp:0.79,language:"English",population:0.066,government:"Republic",colors:["green","yellow","black","white","red","purple"],famous:false,lat:15.4,lon:-61.4),
            Country(name:"Dominican Republic",code:"DOM",flag:"🇩🇴",continent:"North America",area:18.792,gdp:136.15,language:"Spanish",population:11.6,government:"Republic",colors:["blue","red","white","green","yellow"],famous:false,lat:18.7,lon:-70.2),
            Country(name:"East Timor",code:"TLS",flag:"🇹🇱",continent:"Asia",area:5.743,gdp:2.17,language:"Tetum",population:1.4,government:"Republic",colors:["red","yellow","black","white"],famous:false,lat:-8.9,lon:125.7),
            Country(name:"Ecuador",code:"ECU",flag:"🇪🇨",continent:"South America",area:106.889,gdp:138.19,language:"Spanish",population:18.44,government:"Republic",colors:["yellow","blue","red","brown","green"],famous:false,lat:-1.8,lon:-78.2),
            Country(name:"Egypt",code:"EGY",flag:"🇪🇬",continent:"Africa",area:387.048,gdp:429.64,language:"Arabic",population:120.1,government:"Republic",colors:["red","white","black","yellow"],famous:true,lat:26.8,lon:30.8),
            Country(name:"El Salvador",code:"SLV",flag:"🇸🇻",continent:"North America",area:8.124,gdp:39.84,language:"Spanish",population:6.4,government:"Republic",colors:["blue","white","yellow","green"],famous:false,lat:13.8,lon:-88.9),
            Country(name:"Equatorial Guinea",code:"GNQ",flag:"🇬🇶",continent:"Africa",area:10.831,gdp:13.72,language:"Spanish",population:2.0,government:"Republic",colors:["green","white","red","blue","brown","grey"],famous:false,lat:1.7,lon:10.3),
            Country(name:"Eritrea",code:"ERI",flag:"🇪🇷",continent:"Africa",area:45.406,gdp:2.28,language:"Tigrinya",population:3.7,government:"One-party state",colors:["green","red","blue","yellow"],famous:false,lat:15.2,lon:39.8),
            Country(name:"Estonia",code:"EST",flag:"🇪🇪",continent:"Europe",area:17.462,gdp:51.63,language:"Estonian",population:1.3,government:"Republic",colors:["blue","black","white"],famous:false,lat:58.6,lon:25.0),
            Country(name:"Eswatini",code:"SWZ",flag:"🇸🇿",continent:"Africa",area:6.704,gdp:5.79,language:"Swazi",population:1.3,government:"Absolute monarchy",colors:["blue","yellow","red","white","black"],famous:false,lat:-26.5,lon:31.5),
            Country(name:"Ethiopia",code:"ETH",flag:"🇪🇹",continent:"Africa",area:426.372,gdp:121.53,language:"Amharic",population:138.9,government:"Republic",colors:["green","yellow","red","blue"],famous:true,lat:9.1,lon:40.5),
            Country(name:"Federated States of Micronesia",code:"FSM",flag:"🇫🇲",continent:"Oceania",area:0.271,gdp:0.52,language:"English",population:0.1,government:"Republic",colors:["blue","white"],famous:false,lat:7.4,lon:150.6),
            Country(name:"Fiji",code:"FJI",flag:"🇫🇯",continent:"Oceania",area:7.055,gdp:6.35,language:"English",population:0.9,government:"Republic",colors:["blue","white","red","yellow","brown"],famous:true,lat:-17.7,lon:178.1),
            Country(name:"Finland",code:"FIN",flag:"🇫🇮",continent:"Europe",area:130.666,gdp:337.67,language:"Finnish",population:5.6,government:"Republic",colors:["white","blue"],famous:true,lat:61.9,lon:25.7),
            Country(name:"France",code:"FRA",flag:"🇫🇷",continent:"Europe",area:213.011,gdp:3596.09,language:"French",population:66.7,government:"Republic",colors:["blue","white","red"],famous:true,lat:46.6,lon:2.2),
            Country(name:"Gabon",code:"GAB",flag:"🇬🇦",continent:"Africa",area:103.347,gdp:23.36,language:"French",population:2.6,government:"Republic",colors:["green","yellow","blue"],famous:false,lat:-0.8,lon:11.6),
            Country(name:"Gambia",code:"GMB",flag:"🇬🇲",continent:"Africa",area:4.127,gdp:2.79,language:"English",population:2.9,government:"Republic",colors:["red","blue","green","white"],famous:false,lat:13.4,lon:-15.3),
            Country(name:"Georgia",code:"GEO",flag:"🇬🇪",continent:"Asia",area:26.911,gdp:42.72,language:"Georgian",population:3.8,government:"Republic",colors:["white","red"],famous:false,lat:42.3,lon:43.4),
            Country(name:"Germany",code:"DEU",flag:"🇩🇪",continent:"Europe",area:137.882,gdp:5452.86,language:"German",population:83.6,government:"Republic",colors:["black","red","yellow"],famous:true,lat:51.2,lon:10.5),
            Country(name:"Ghana",code:"GHA",flag:"🇬🇭",continent:"Africa",area:92.098,gdp:118.29,language:"English",population:35.7,government:"Republic",colors:["red","yellow","green","black"],famous:true,lat:7.9,lon:-1.0),
            Country(name:"Greece",code:"GRC",flag:"🇬🇷",continent:"Europe",area:50.962,gdp:307.55,language:"Greek",population:9.9,government:"Republic",colors:["blue","white"],famous:true,lat:39.1,lon:21.8),
            Country(name:"Grenada",code:"GRD",flag:"🇬🇩",continent:"North America",area:0.133,gdp:1.48,language:"English",population:0.117,government:"Const. monarchy",colors:["red","yellow","green"],famous:false,lat:12.1,lon:-61.7),
            Country(name:"Guatemala",code:"GTM",flag:"🇬🇹",continent:"North America",area:42.042,gdp:128.89,language:"Spanish",population:19.0,government:"Republic",colors:["blue","white","green","brown"],famous:false,lat:15.8,lon:-90.2),
            Country(name:"Guinea",code:"GIN",flag:"🇬🇳",continent:"Africa",area:94.926,gdp:29.93,language:"French",population:15.44,government:"Republic",colors:["red","yellow","green"],famous:false,lat:9.9,lon:-9.7),
            Country(name:"Guinea-Bissau",code:"GNB",flag:"🇬🇼",continent:"Africa",area:13.948,gdp:2.98,language:"Portuguese",population:2.3,government:"Republic",colors:["red","yellow","green","black"],famous:false,lat:11.8,lon:-15.2),
            Country(name:"Guyana",code:"GUY",flag:"🇬🇾",continent:"South America",area:83.0,gdp:33.96,language:"English",population:0.8,government:"Republic",colors:["green","white","yellow","red","black"],famous:false,lat:4.9,lon:-58.9),
            Country(name:"Haiti",code:"HTI",flag:"🇭🇹",continent:"North America",area:10.714,gdp:39.18,language:"Haitian Creole",population:12.04,government:"Republic",colors:["blue","red","white","green","yellow"],famous:false,lat:19.0,lon:-72.3),
            Country(name:"Honduras",code:"HND",flag:"🇭🇳",continent:"North America",area:43.433,gdp:41.51,language:"Spanish",population:11.2,government:"Republic",colors:["blue","white","green"],famous:false,lat:15.2,lon:-86.2),
            Country(name:"Hungary",code:"HUN",flag:"🇭🇺",continent:"Europe",area:35.918,gdp:271.12,language:"Hungarian",population:9.6,government:"Republic",colors:["red","white","green"],famous:true,lat:47.2,lon:19.5),
            Country(name:"Iceland",code:"ISL",flag:"🇮🇸",continent:"Europe",area:39.769,gdp:43.8,language:"Icelandic",population:0.4,government:"Republic",colors:["blue","white","red"],famous:true,lat:64.9,lon:-19.0),
            Country(name:"India",code:"IND",flag:"🇮🇳",continent:"Asia",area:1269.345,gdp:4153.19,language:"Hindi",population:1476.6,government:"Republic",colors:["orange","white","green","blue"],famous:true,lat:20.6,lon:79.0),
            Country(name:"Indonesia",code:"IDN",flag:"🇮🇩",continent:"Asia",area:735.358,gdp:1539.87,language:"Indonesian",population:287.9,government:"Republic",colors:["red","white"],famous:true,lat:-0.8,lon:113.9),
            Country(name:"Iran",code:"IRN",flag:"🇮🇷",continent:"Asia",area:636.371,gdp:300.29,language:"Persian",population:93.2,government:"Theocracy",colors:["green","white","red"],famous:true,lat:32.4,lon:53.7),
            Country(name:"Iraq",code:"IRQ",flag:"🇮🇶",continent:"Asia",area:169.235,gdp:264.78,language:"Arabic",population:48.0,government:"Republic",colors:["red","white","black","green"],famous:true,lat:33.2,lon:43.7),
            Country(name:"Ireland",code:"IRL",flag:"🇮🇪",continent:"Europe",area:27.133,gdp:779.38,language:"English",population:5.4,government:"Republic",colors:["green","white","orange"],famous:true,lat:53.4,lon:-8.2),
            Country(name:"Israel",code:"ISR",flag:"🇮🇱",continent:"Asia",area:8.019,gdp:719.85,language:"Hebrew",population:9.6,government:"Republic",colors:["blue","white"],famous:true,lat:31.0,lon:34.9),
            Country(name:"Italy",code:"ITA",flag:"🇮🇹",continent:"Europe",area:116.346,gdp:2738.16,language:"Italian",population:58.9,government:"Republic",colors:["green","white","red"],famous:true,lat:41.9,lon:12.6),
            Country(name:"Ivory Coast",code:"CIV",flag:"🇨🇮",continent:"Africa",area:124.504,gdp:112.11,language:"French",population:33.5,government:"Republic",colors:["orange","white","green"],famous:false,lat:7.5,lon:-5.5),
            Country(name:"Jamaica",code:"JAM",flag:"🇯🇲",continent:"North America",area:4.244,gdp:23.03,language:"English",population:2.8,government:"Const. monarchy",colors:["green","yellow","black"],famous:true,lat:18.1,lon:-77.3),
            Country(name:"Japan",code:"JPN",flag:"🇯🇵",continent:"Asia",area:145.92,gdp:4379.25,language:"Japanese",population:122.4,government:"Const. monarchy",colors:["white","red"],famous:true,lat:36.2,lon:138.3),
            Country(name:"Jordan",code:"JOR",flag:"🇯🇴",continent:"Asia",area:34.495,gdp:64.91,language:"Arabic",population:11.6,government:"Const. monarchy",colors:["black","white","red","green"],famous:true,lat:30.6,lon:36.2),
            Country(name:"Kazakhstan",code:"KAZ",flag:"🇰🇿",continent:"Asia",area:1052.089,gdp:360.46,language:"Kazakh",population:21.1,government:"Republic",colors:["blue","yellow"],famous:false,lat:48.0,lon:66.9),
            Country(name:"Kenya",code:"KEN",flag:"🇰🇪",continent:"Africa",area:224.081,gdp:147.26,language:"Swahili",population:58.6,government:"Republic",colors:["black","red","green","white"],famous:true,lat:-0.0,lon:37.9),
            Country(name:"Kiribati",code:"KIR",flag:"🇰🇮",continent:"Oceania",area:0.313,gdp:0.4,language:"English",population:0.138,government:"Republic",colors:["red","white","blue","yellow"],famous:false,lat:1.9,lon:-157.4),
            Country(name:"Kuwait",code:"KWT",flag:"🇰🇼",continent:"Asia",area:6.88,gdp:172.92,language:"Arabic",population:5.1,government:"Const. monarchy",colors:["green","white","red","black"],famous:true,lat:29.3,lon:47.5),
            Country(name:"Kyrgyzstan",code:"KGZ",flag:"🇰🇬",continent:"Asia",area:77.201,gdp:23.61,language:"Kyrgyz",population:7.4,government:"Republic",colors:["red","yellow"],famous:false,lat:41.2,lon:74.8),
            Country(name:"Laos",code:"LAO",flag:"🇱🇦",continent:"Asia",area:91.429,gdp:18.96,language:"Lao",population:8.0,government:"One-party state",colors:["red","blue","white"],famous:false,lat:19.9,lon:102.5),
            Country(name:"Latvia",code:"LVA",flag:"🇱🇻",continent:"Europe",area:24.926,gdp:53.69,language:"Latvian",population:1.8,government:"Republic",colors:["red","white"],famous:false,lat:56.9,lon:24.6),
            Country(name:"Lebanon",code:"LBN",flag:"🇱🇧",continent:"Asia",area:4.036,gdp:34.5,language:"Arabic",population:5.9,government:"Republic",colors:["red","white","green"],famous:true,lat:33.9,lon:35.9),
            Country(name:"Lesotho",code:"LSO",flag:"🇱🇸",continent:"Africa",area:11.72,gdp:2.97,language:"Sotho",population:2.4,government:"Const. monarchy",colors:["blue","white","green","black"],famous:false,lat:-29.6,lon:28.2),
            Country(name:"Liberia",code:"LBR",flag:"🇱🇷",continent:"Africa",area:43.0,gdp:5.64,language:"English",population:5.9,government:"Republic",colors:["red","white","blue"],famous:false,lat:6.4,lon:-9.4),
            Country(name:"Libya",code:"LBY",flag:"🇱🇾",continent:"Africa",area:679.362,gdp:52.45,language:"Arabic",population:7.5,government:"Republic",colors:["red","black","green"],famous:true,lat:26.3,lon:17.2),
            Country(name:"Liechtenstein",code:"LIE",flag:"🇱🇮",continent:"Europe",area:0.062,gdp:9.44,language:"German",population:0.04,government:"Const. monarchy",colors:["blue","red","yellow","black"],famous:false,lat:47.2,lon:9.6),
            Country(name:"Lithuania",code:"LTU",flag:"🇱🇹",continent:"Europe",area:25.212,gdp:105.91,language:"Lithuanian",population:2.8,government:"Republic",colors:["yellow","green","red"],famous:false,lat:55.2,lon:23.9),
            Country(name:"Luxembourg",code:"LUX",flag:"🇱🇺",continent:"Europe",area:0.998,gdp:110.42,language:"Luxembourgish",population:0.7,government:"Const. monarchy",colors:["red","white","blue"],famous:false,lat:49.8,lon:6.1),
            Country(name:"Madagascar",code:"MDG",flag:"🇲🇬",continent:"Africa",area:226.658,gdp:21.18,language:"Malagasy",population:33.5,government:"Republic",colors:["white","red","green"],famous:false,lat:-18.8,lon:46.9),
            Country(name:"Malawi",code:"MWI",flag:"🇲🇼",continent:"Africa",area:45.747,gdp:18.15,language:"English",population:22.8,government:"Republic",colors:["black","red","green","white"],famous:false,lat:-13.3,lon:34.3),
            Country(name:"Malaysia",code:"MYS",flag:"🇲🇾",continent:"Asia",area:127.724,gdp:516.43,language:"Malay",population:36.4,government:"Const. monarchy",colors:["red","white","blue","yellow"],famous:true,lat:4.2,lon:109.7),
            Country(name:"Maldives",code:"MDV",flag:"🇲🇻",continent:"Asia",area:0.116,gdp:8.13,language:"Dhivehi",population:0.5,government:"Republic",colors:["red","green","white"],famous:false,lat:3.2,lon:73.2),
            Country(name:"Mali",code:"MLI",flag:"🇲🇱",continent:"Africa",area:478.841,gdp:33.85,language:"French",population:25.9,government:"Republic",colors:["green","yellow","red"],famous:false,lat:17.6,lon:-4.0),
            Country(name:"Malta",code:"MLT",flag:"🇲🇹",continent:"Europe",area:0.122,gdp:30.71,language:"Maltese",population:0.5,government:"Republic",colors:["white","red"],famous:false,lat:35.9,lon:14.4),
            Country(name:"Marshall Islands",code:"MHL",flag:"🇲🇭",continent:"Oceania",area:0.07,gdp:0.34,language:"English",population:0.035,government:"Republic",colors:["blue","white","orange"],famous:false,lat:7.1,lon:171.2),
            Country(name:"Mauritania",code:"MRT",flag:"🇲🇷",continent:"Africa",area:397.955,gdp:14.35,language:"Arabic",population:5.5,government:"Republic",colors:["green","yellow","red"],famous:false,lat:21.0,lon:-10.9),
            Country(name:"Mauritius",code:"MUS",flag:"🇲🇺",continent:"Africa",area:0.788,gdp:17.12,language:"English",population:1.3,government:"Republic",colors:["red","blue","yellow","green"],famous:false,lat:-20.3,lon:57.6),
            Country(name:"Mexico",code:"MEX",flag:"🇲🇽",continent:"North America",area:758.449,gdp:2120.86,language:"Spanish",population:133.0,government:"Republic",colors:["green","white","red","brown"],famous:true,lat:23.6,lon:-102.6),
            Country(name:"Moldova",code:"MDA",flag:"🇲🇩",continent:"Europe",area:13.068,gdp:21.89,language:"Romanian",population:3.0,government:"Republic",colors:["blue","yellow","red","brown"],famous:false,lat:47.4,lon:28.4),
            Country(name:"Monaco",code:"MCO",flag:"🇲🇨",continent:"Europe",area:0.001,gdp:10.0,language:"French",population:0.038,government:"Const. monarchy",colors:["red","white"],famous:false,lat:43.7,lon:7.4),
            Country(name:"Mongolia",code:"MNG",flag:"🇲🇳",continent:"Asia",area:603.906,gdp:28.45,language:"Mongolian",population:3.6,government:"Republic",colors:["red","blue","yellow"],famous:false,lat:46.9,lon:103.8),
            Country(name:"Montenegro",code:"MNE",flag:"🇲🇪",continent:"Europe",area:5.333,gdp:10.23,language:"Montenegrin",population:0.6,government:"Republic",colors:["red","yellow","blue"],famous:false,lat:42.7,lon:19.4),
            Country(name:"Morocco",code:"MAR",flag:"🇲🇦",continent:"Africa",area:172.414,gdp:194.33,language:"Arabic",population:38.8,government:"Const. monarchy",colors:["red","green"],famous:true,lat:31.8,lon:-7.1),
            Country(name:"Mozambique",code:"MOZ",flag:"🇲🇿",continent:"Africa",area:309.496,gdp:23.27,language:"Portuguese",population:36.6,government:"Republic",colors:["green","black","yellow","white","red"],famous:false,lat:-18.7,lon:35.5),
            Country(name:"Myanmar",code:"MMR",flag:"🇲🇲",continent:"Asia",area:261.228,gdp:83.83,language:"Burmese",population:55.2,government:"Republic",colors:["yellow","green","red","white"],famous:false,lat:21.9,lon:95.96),
            Country(name:"Namibia",code:"NAM",flag:"🇳🇦",continent:"Africa",area:318.772,gdp:17.31,language:"English",population:3.2,government:"Republic",colors:["blue","red","green","white","yellow"],famous:false,lat:-22.96,lon:18.5),
            Country(name:"Nauru",code:"NRU",flag:"🇳🇷",continent:"Oceania",area:0.008,gdp:0.2,language:"English",population:0.012,government:"Republic",colors:["blue","yellow","white"],famous:false,lat:-0.5,lon:166.9),
            Country(name:"Nepal",code:"NPL",flag:"🇳🇵",continent:"Asia",area:56.827,gdp:45.84,language:"Nepali",population:29.6,government:"Republic",colors:["red","blue","white"],famous:false,lat:28.4,lon:84.1),
            Country(name:"Netherlands",code:"NLD",flag:"🇳🇱",continent:"Europe",area:16.158,gdp:1449.7,language:"Dutch",population:18.4,government:"Const. monarchy",colors:["red","white","blue"],famous:true,lat:52.1,lon:5.3),
            Country(name:"New Zealand",code:"NZL",flag:"🇳🇿",continent:"Oceania",area:104.428,gdp:278.64,language:"English",population:5.3,government:"Const. monarchy",colors:["blue","red","white"],famous:true,lat:-40.9,lon:174.9),
            Country(name:"Nicaragua",code:"NIC",flag:"🇳🇮",continent:"North America",area:50.337,gdp:24.23,language:"Spanish",population:7.1,government:"Republic",colors:["blue","white","yellow","green"],famous:false,lat:12.9,lon:-85.2),
            Country(name:"Niger",code:"NER",flag:"🇳🇪",continent:"Africa",area:489.191,gdp:24.81,language:"Hausa",population:28.8,government:"Republic",colors:["orange","white","green"],famous:false,lat:17.6,lon:8.1),
            Country(name:"Nigeria",code:"NGA",flag:"🇳🇬",continent:"Africa",area:356.669,gdp:377.37,language:"English",population:242.4,government:"Republic",colors:["green","white"],famous:true,lat:9.1,lon:8.7),
            Country(name:"North Korea",code:"PRK",flag:"🇰🇵",continent:"Asia",area:46.54,gdp:16.45,language:"Korean",population:26.6,government:"One-party state",colors:["blue","red","white"],famous:true,lat:40.3,lon:127.5),
            Country(name:"North Macedonia",code:"MKD",flag:"🇲🇰",continent:"Europe",area:9.928,gdp:21.61,language:"Macedonian",population:1.8,government:"Republic",colors:["red","yellow"],famous:false,lat:41.6,lon:21.7),
            Country(name:"Norway",code:"NOR",flag:"🇳🇴",continent:"Europe",area:125.021,gdp:599.41,language:"Norwegian",population:5.7,government:"Const. monarchy",colors:["red","white","blue"],famous:true,lat:60.5,lon:8.5),
            Country(name:"Oman",code:"OMN",flag:"🇴🇲",continent:"Asia",area:119.499,gdp:117.18,language:"Arabic",population:5.7,government:"Absolute monarchy",colors:["red","white","green"],famous:false,lat:21.5,lon:55.9),
            Country(name:"Pakistan",code:"PAK",flag:"🇵🇰",continent:"Asia",area:340.508,gdp:407.79,language:"Urdu",population:259.3,government:"Republic",colors:["green","white"],famous:true,lat:30.4,lon:69.3),
            Country(name:"Palau",code:"PLW",flag:"🇵🇼",continent:"Oceania",area:0.177,gdp:0.38,language:"English",population:0.018,government:"Republic",colors:["blue","yellow"],famous:false,lat:7.5,lon:134.6),
            Country(name:"Palestine",code:"PSE",flag:"🇵🇸",continent:"Asia",area:2.402,gdp:13.71,language:"Arabic",population:5.7,government:"Republic",colors:["black","white","green","red"],famous:false,lat:31.9,lon:35.2),
            Country(name:"Panama",code:"PAN",flag:"🇵🇦",continent:"North America",area:29.119,gdp:95.02,language:"Spanish",population:4.6,government:"Republic",colors:["red","white","blue"],famous:false,lat:8.5,lon:-80.8),
            Country(name:"Papua New Guinea",code:"PNG",flag:"🇵🇬",continent:"Oceania",area:178.703,gdp:34.4,language:"English",population:10.9,government:"Const. monarchy",colors:["red","black","yellow","white"],famous:false,lat:-6.3,lon:143.9),
            Country(name:"Paraguay",code:"PRY",flag:"🇵🇾",continent:"South America",area:157.048,gdp:60.54,language:"Spanish",population:7.1,government:"Republic",colors:["red","white","blue","yellow","green"],famous:false,lat:-23.4,lon:-58.4),
            Country(name:"Peru",code:"PER",flag:"🇵🇪",continent:"South America",area:496.224,gdp:380.9,language:"Spanish",population:34.9,government:"Republic",colors:["red","white","green","yellow","brown"],famous:true,lat:-9.2,lon:-75.0),
            Country(name:"Philippines",code:"PHL",flag:"🇵🇭",continent:"Asia",area:132.183,gdp:512.22,language:"Filipino",population:117.7,government:"Republic",colors:["blue","red","white","yellow","brown"],famous:true,lat:12.9,lon:121.8),
            Country(name:"Poland",code:"POL",flag:"🇵🇱",continent:"Europe",area:120.726,gdp:1134.25,language:"Polish",population:37.8,government:"Republic",colors:["white","red"],famous:true,lat:51.9,lon:19.1),
            Country(name:"Portugal",code:"PRT",flag:"🇵🇹",continent:"Europe",area:35.556,gdp:380.64,language:"Portuguese",population:10.4,government:"Republic",colors:["green","red","white","yellow","blue"],famous:true,lat:39.4,lon:-8.2),
            Country(name:"Qatar",code:"QAT",flag:"🇶🇦",continent:"Asia",area:4.473,gdp:217.42,language:"Arabic",population:3.2,government:"Const. monarchy",colors:["red","white"],famous:true,lat:25.4,lon:51.2),
            Country(name:"Republic of the Congo",code:"COG",flag:"🇨🇬",continent:"Africa",area:132.047,gdp:17.03,language:"French",population:6.6,government:"Republic",colors:["green","yellow","red"],famous:false,lat:-0.2,lon:15.8),
            Country(name:"Romania",code:"ROU",flag:"🇷🇴",continent:"Europe",area:92.043,gdp:480.83,language:"Romanian",population:18.8,government:"Republic",colors:["blue","yellow","red"],famous:true,lat:45.9,lon:24.97),
            Country(name:"Russia",code:"RUS",flag:"🇷🇺",continent:"Europe",area:6601.665,gdp:2656.45,language:"Russian",population:143.4,government:"Republic",colors:["white","blue","red"],famous:true,lat:61.5,lon:105.3),
            Country(name:"Rwanda",code:"RWA",flag:"🇷🇼",continent:"Africa",area:10.169,gdp:17.34,language:"Kinyarwanda",population:14.89,government:"Republic",colors:["blue","yellow","green"],famous:false,lat:-1.9,lon:29.9),
            Country(name:"Saint Kitts and Nevis",code:"KNA",flag:"🇰🇳",continent:"North America",area:0.101,gdp:1.14,language:"English",population:0.047,government:"Const. monarchy",colors:["green","yellow","red","black","white"],famous:false,lat:17.4,lon:-62.8),
            Country(name:"Saint Lucia",code:"LCA",flag:"🇱🇨",continent:"North America",area:0.238,gdp:2.77,language:"English",population:0.2,government:"Const. monarchy",colors:["blue","yellow","black","white"],famous:false,lat:13.9,lon:-61.0),
            Country(name:"Saint Vincent and the Grenadines",code:"VCT",flag:"🇻🇨",continent:"North America",area:0.15,gdp:1.24,language:"English",population:0.099,government:"Const. monarchy",colors:["blue","yellow","green"],famous:false,lat:13.0,lon:-61.3),
            Country(name:"Samoa",code:"WSM",flag:"🇼🇸",continent:"Oceania",area:1.097,gdp:1.38,language:"Samoan",population:0.2,government:"Republic",colors:["red","blue","white"],famous:false,lat:-13.8,lon:-172.1),
            Country(name:"San Marino",code:"SMR",flag:"🇸🇲",continent:"Europe",area:0.024,gdp:2.42,language:"Italian",population:0.034,government:"Republic",colors:["white","blue","yellow","green"],famous:false,lat:43.9,lon:12.5),
            Country(name:"Sao Tome and Principe",code:"STP",flag:"🇸🇹",continent:"Africa",area:0.372,gdp:1.16,language:"Portuguese",population:0.2,government:"Republic",colors:["green","yellow","red","black"],famous:false,lat:0.2,lon:6.6),
            Country(name:"Saudi Arabia",code:"SAU",flag:"🇸🇦",continent:"Asia",area:830.0,gdp:1388.68,language:"Arabic",population:35.2,government:"Absolute monarchy",colors:["green","white"],famous:true,lat:23.9,lon:45.1),
            Country(name:"Senegal",code:"SEN",flag:"🇸🇳",continent:"Africa",area:75.955,gdp:40.47,language:"French",population:19.4,government:"Republic",colors:["green","yellow","red"],famous:false,lat:14.5,lon:-14.5),
            Country(name:"Serbia",code:"SRB",flag:"🇷🇸",continent:"Europe",area:34.116,gdp:112.03,language:"Serbian",population:6.6,government:"Republic",colors:["red","blue","white","yellow"],famous:false,lat:44.0,lon:21.0),
            Country(name:"Seychelles",code:"SYC",flag:"🇸🇨",continent:"Africa",area:0.175,gdp:2.25,language:"Seychellois Creole",population:0.135,government:"Republic",colors:["blue","yellow","red","white","green"],famous:false,lat:-4.7,lon:55.5),
            Country(name:"Sierra Leone",code:"SLE",flag:"🇸🇱",continent:"Africa",area:27.699,gdp:8.27,language:"English",population:9.0,government:"Republic",colors:["green","white","blue"],famous:false,lat:8.5,lon:-11.8),
            Country(name:"Singapore",code:"SGP",flag:"🇸🇬",continent:"Asia",area:0.274,gdp:659.57,language:"English",population:5.9,government:"Republic",colors:["red","white"],famous:true,lat:1.35,lon:103.8),
            Country(name:"Slovakia",code:"SVK",flag:"🇸🇰",continent:"Europe",area:18.933,gdp:168.9,language:"Slovak",population:5.5,government:"Republic",colors:["white","blue","red","yellow"],famous:false,lat:48.7,lon:19.7),
            Country(name:"Slovenia",code:"SVN",flag:"🇸🇮",continent:"Europe",area:7.827,gdp:86.73,language:"Slovene",population:2.1,government:"Republic",colors:["white","blue","red","yellow"],famous:false,lat:46.2,lon:15.0),
            Country(name:"Solomon Islands",code:"SLB",flag:"🇸🇧",continent:"Oceania",area:11.157,gdp:1.84,language:"English",population:0.9,government:"Const. monarchy",colors:["blue","yellow","green","white"],famous:false,lat:-9.6,lon:160.2),
            Country(name:"Somalia",code:"SOM",flag:"🇸🇴",continent:"Africa",area:246.201,gdp:14.17,language:"Somali",population:20.3,government:"Republic",colors:["blue","white"],famous:false,lat:5.2,lon:46.2),
            Country(name:"South Africa",code:"ZAF",flag:"🇿🇦",continent:"Africa",area:471.445,gdp:479.96,language:"Zulu",population:65.5,government:"Republic",colors:["red","white","blue","green","yellow","black"],famous:true,lat:-30.6,lon:22.9),
            Country(name:"South Korea",code:"KOR",flag:"🇰🇷",continent:"Asia",area:38.691,gdp:1931.01,language:"Korean",population:51.6,government:"Republic",colors:["white","red","blue","black"],famous:true,lat:35.9,lon:127.8),
            Country(name:"South Sudan",code:"SSD",flag:"🇸🇸",continent:"Africa",area:239.285,gdp:6.07,language:"English",population:12.44,government:"Republic",colors:["black","red","green","white","blue","yellow"],famous:false,lat:7.0,lon:30.0),
            Country(name:"Spain",code:"ESP",flag:"🇪🇸",continent:"Europe",area:195.365,gdp:2091.22,language:"Spanish",population:47.9,government:"Const. monarchy",colors:["red","yellow","blue","purple"],famous:true,lat:40.5,lon:-3.7),
            Country(name:"Sri Lanka",code:"LKA",flag:"🇱🇰",continent:"Asia",area:25.332,gdp:98.96,language:"Sinhala",population:23.3,government:"Republic",colors:["yellow","red","green","orange"],famous:false,lat:7.9,lon:80.8),
            Country(name:"Sudan",code:"SDN",flag:"🇸🇩",continent:"Africa",area:728.215,gdp:44.69,language:"Arabic",population:53.3,government:"Republic",colors:["red","white","black","green"],famous:false,lat:15.5,lon:30.2),
            Country(name:"Suriname",code:"SUR",flag:"🇸🇷",continent:"South America",area:63.251,gdp:5.91,language:"Dutch",population:0.6,government:"Republic",colors:["green","white","red","yellow"],famous:false,lat:4.0,lon:-56.0),
            Country(name:"Sweden",code:"SWE",flag:"🇸🇪",continent:"Europe",area:173.86,gdp:760.48,language:"Swedish",population:10.7,government:"Const. monarchy",colors:["blue","yellow"],famous:true,lat:60.1,lon:18.6),
            Country(name:"Switzerland",code:"CHE",flag:"🇨🇭",continent:"Europe",area:15.94,gdp:1146.91,language:"German",population:9.0,government:"Republic",colors:["red","white"],famous:true,lat:46.8,lon:8.2),
            Country(name:"Syria",code:"SYR",flag:"🇸🇾",continent:"Asia",area:71.498,gdp:19.99,language:"Arabic",population:26.5,government:"Republic",colors:["green","white","black","red"],famous:true,lat:34.8,lon:38.99),
            Country(name:"Tajikistan",code:"TJK",flag:"🇹🇯",continent:"Asia",area:55.251,gdp:20.42,language:"Tajik",population:10.98,government:"Republic",colors:["red","white","green","yellow"],famous:false,lat:38.9,lon:71.3),
            Country(name:"Tanzania",code:"TZA",flag:"🇹🇿",continent:"Africa",area:364.9,gdp:94.89,language:"Swahili",population:72.6,government:"Republic",colors:["green","yellow","black","blue"],famous:true,lat:-6.4,lon:34.9),
            Country(name:"Thailand",code:"THA",flag:"🇹🇭",continent:"Asia",area:198.117,gdp:580.0,language:"Thai",population:71.6,government:"Const. monarchy",colors:["red","white","blue"],famous:true,lat:15.9,lon:101.0),
            Country(name:"Togo",code:"TGO",flag:"🇹🇬",continent:"Africa",area:21.925,gdp:13.44,language:"French",population:9.9,government:"Republic",colors:["green","yellow","red","white"],famous:false,lat:8.6,lon:0.8),
            Country(name:"Tonga",code:"TON",flag:"🇹🇴",continent:"Oceania",area:0.288,gdp:0.72,language:"English",population:0.103,government:"Const. monarchy",colors:["red","white"],famous:false,lat:-21.2,lon:-175.2),
            Country(name:"Trinidad and Tobago",code:"TTO",flag:"🇹🇹",continent:"North America",area:1.981,gdp:26.84,language:"English",population:1.5,government:"Republic",colors:["red","white","black"],famous:false,lat:10.7,lon:-61.2),
            Country(name:"Tunisia",code:"TUN",flag:"🇹🇳",continent:"Africa",area:63.17,gdp:60.74,language:"Arabic",population:12.4,government:"Republic",colors:["red","white"],famous:true,lat:33.9,lon:9.6),
            Country(name:"Turkey",code:"TUR",flag:"🇹🇷",continent:"Asia",area:302.535,gdp:1640.22,language:"Turkish",population:87.9,government:"Republic",colors:["red","white"],famous:true,lat:38.96,lon:35.2),
            Country(name:"Turkmenistan",code:"TKM",flag:"🇹🇲",continent:"Asia",area:188.456,gdp:83.06,language:"Turkmen",population:7.7,government:"Republic",colors:["green","white","red"],famous:false,lat:38.97,lon:59.6),
            Country(name:"Tuvalu",code:"TUV",flag:"🇹🇻",continent:"Oceania",area:0.01,gdp:0.07,language:"Tuvaluan",population:0.009,government:"Const. monarchy",colors:["blue","yellow","white","red"],famous:false,lat:-7.1,lon:177.6),
            Country(name:"Uganda",code:"UGA",flag:"🇺🇬",continent:"Africa",area:93.263,gdp:73.37,language:"English",population:52.8,government:"Republic",colors:["black","yellow","red","white"],famous:false,lat:1.4,lon:32.3),
            Country(name:"Ukraine",code:"UKR",flag:"🇺🇦",continent:"Europe",area:233.013,gdp:225.34,language:"Ukrainian",population:39.5,government:"Republic",colors:["blue","yellow"],famous:true,lat:48.4,lon:31.2),
            Country(name:"United Arab Emirates",code:"ARE",flag:"🇦🇪",continent:"Asia",area:32.278,gdp:621.55,language:"Arabic",population:11.6,government:"Const. monarchy",colors:["green","white","black","red"],famous:true,lat:23.4,lon:53.8),
            Country(name:"United Kingdom",code:"GBR",flag:"🇬🇧",continent:"Europe",area:93.784,gdp:4264.79,language:"English",population:69.9,government:"Const. monarchy",colors:["blue","white","red"],famous:true,lat:55.4,lon:-3.4),
            Country(name:"United States",code:"USA",flag:"🇺🇸",continent:"North America",area:3618.783,gdp:32383.92,language:"English",population:349.0,government:"Republic",colors:["red","white","blue"],famous:true,lat:37.1,lon:-95.7),
            Country(name:"Uruguay",code:"URY",flag:"🇺🇾",continent:"South America",area:69.898,gdp:96.09,language:"Spanish",population:3.4,government:"Republic",colors:["blue","white","yellow","brown"],famous:false,lat:-32.5,lon:-55.8),
            Country(name:"Uzbekistan",code:"UZB",flag:"🇺🇿",continent:"Asia",area:172.742,gdp:181.5,language:"Uzbek",population:37.7,government:"Republic",colors:["blue","white","green","red"],famous:false,lat:41.4,lon:64.6),
            Country(name:"Vanuatu",code:"VUT",flag:"🇻🇺",continent:"Oceania",area:4.706,gdp:1.4,language:"Bislama",population:0.3,government:"Republic",colors:["black","red","green","yellow"],famous:false,lat:-15.4,lon:166.9),
            Country(name:"Vatican City",code:"VAT",flag:"🇻🇦",continent:"Europe",area:0.0002,gdp:0.02,language:"Italian",population:0.001,government:"Absolute monarchy",colors:["yellow","white","grey"],famous:false,lat:41.9,lon:12.45),
            Country(name:"Venezuela",code:"VEN",flag:"🇻🇪",continent:"South America",area:353.841,gdp:111.3,language:"Spanish",population:28.6,government:"Republic",colors:["yellow","blue","red","white","brown"],famous:true,lat:6.4,lon:-66.6),
            Country(name:"Vietnam",code:"VNM",flag:"🇻🇳",continent:"Asia",area:127.882,gdp:527.27,language:"Vietnamese",population:102.2,government:"One-party state",colors:["red","yellow"],famous:true,lat:14.06,lon:108.3),
            Country(name:"Yemen",code:"YEM",flag:"🇾🇪",continent:"Asia",area:203.85,gdp:7.43,language:"Arabic",population:43.0,government:"Republic",colors:["red","white","black"],famous:false,lat:15.6,lon:48.0),
            Country(name:"Zambia",code:"ZMB",flag:"🇿🇲",continent:"Africa",area:290.585,gdp:41.24,language:"English",population:22.5,government:"Republic",colors:["green","red","black","orange"],famous:false,lat:-13.1,lon:27.8),
            Country(name:"Zimbabwe",code:"ZWE",flag:"🇿🇼",continent:"Africa",area:150.872,gdp:56.71,language:"Shona",population:17.27,government:"Republic",colors:["green","yellow","red","black","white"],famous:false,lat:-19.0,lon:29.2)
        ]
    }
}

// MARK: - Root View

struct RootView: View {
    @StateObject private var data = AppDataManager()
    @StateObject private var settings = Settings()

    var body: some View {
        ZStack {
            Theme.paper.ignoresSafeArea()
            MainTabs()
        }
        .environmentObject(data)
        .environmentObject(settings)
        .fullScreenCover(isPresented: .constant(!settings.hasOnboarded)) {
            OnboardingView()
                .environmentObject(settings)
        }
    }
}

// MARK: - Main Tabs

struct MainTabs: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }
            UnlimitedTab()
                .tabItem { Label("Unlimited", systemImage: "infinity") }
            MapTabView()
                .tabItem { Label("Map", systemImage: "map.fill") }
            TrophyRoomView()
                .tabItem { Label("Trophies", systemImage: "star.fill") }
            StatsView()
                .tabItem { Label("Stats", systemImage: "chart.bar.fill") }
        }
        .tint(Theme.ink)
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @EnvironmentObject var settings: Settings
    @State private var page = 0

    let pages: [(icon: String, title: String, body: String)] = [
        ("globe", "Welcome to Atlasle",
         "Guess the mystery country in eight tries. Each guess reveals how close you are."),
        ("lightbulb", "Read the clues",
         "Continent, size, population, economy, government, language, and flag colors all hint at the answer. Green means exact, amber is close, coral is far."),
        ("calendar", "Daily & Unlimited",
         "Everyone gets the same Daily puzzle — build a streak! Or play Unlimited anytime, with Easy or World difficulty and a no-pressure Practice mode."),
        ("star", "Build your atlas",
         "Win countries to fill your Trophy Room and color them in on the world map.")
    ]

    var body: some View {
        ZStack {
            Theme.paper.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                TabView(selection: $page) {
                    ForEach(pages.indices, id: \.self) { i in
                        VStack(spacing: 22) {
                            if i == 0 {
                                LogoView(size: 120)
                            } else {
                                Image(systemName: pages[i].icon)
                                    .font(.system(size: 64))
                                    .foregroundColor(Theme.ink)
                            }
                            Text(pages[i].title)
                                .font(.custom("Georgia", size: 28))
                                .fontWeight(.black)
                                .foregroundColor(Theme.ink)
                                .multilineTextAlignment(.center)
                            Text(pages[i].body)
                                .font(.system(size: 15, design: .monospaced))
                                .foregroundColor(Theme.inkSoft)
                                .multilineTextAlignment(.center)
                                .lineSpacing(3)
                                .padding(.horizontal, 36)
                            if i == 1 {
                                HStack(spacing: 10) {
                                    legendDot(Theme.green, "Exact")
                                    legendDot(Theme.amber, "Close")
                                    legendDot(Theme.red, "Far")
                                }
                            }
                        }
                        .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                HStack(spacing: 8) {
                    ForEach(pages.indices, id: \.self) { i in
                        Circle()
                            .fill(i == page ? Theme.ink : Theme.line)
                            .frame(width: 8, height: 8)
                    }
                }
                .padding(.top, 12)

                Spacer()

                Button(action: {
                    if page < pages.count - 1 { withAnimation { page += 1 } }
                    else { settings.hasOnboarded = true }
                }) {
                    Text(page < pages.count - 1 ? "Next" : "Start playing")
                        .font(.custom("Georgia", size: 18)).fontWeight(.semibold)
                        .foregroundColor(Theme.paper)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.ink))
                }
                .padding(.horizontal, 28)

                Button("Skip") { settings.hasOnboarded = true }
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(Theme.inkSoft)
                    .padding(.top, 10).padding(.bottom, 30)
            }
        }
    }

    func legendDot(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(c).frame(width: 11, height: 11)
            Text(t).font(.system(size: 12, design: .monospaced)).foregroundColor(Theme.inkSoft)
        }
    }
}

// MARK: - Home (Daily + streak + settings)

struct HomeView: View {
    @EnvironmentObject var data: AppDataManager
    @EnvironmentObject var settings: Settings
    @State private var showDaily = false
    @State private var showSettings = false
    @State private var showAbout = false

    var foundCount: Int {
        Set(data.gameHistory.filter { $0.won }.map { $0.countryCode }).count
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.paper.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 24) {
                        VStack(spacing: 12) {
                            LogoView(size: 88)
                            Text("ATLASLE")
                                .font(.custom("Georgia", size: 52)).fontWeight(.black)
                                .tracking(6).foregroundColor(Theme.ink)
                                .lineLimit(1).minimumScaleFactor(0.5)
                                .shadow(color: Theme.paperDark, radius: 0, x: 2, y: 2)
                            Text("guess the country in eight tries")
                                .font(.custom("Georgia", size: 15)).italic()
                                .foregroundColor(Theme.inkSoft)
                        }
                        .padding(.top, 12)

                        streakCard

                        dailyCard

                        statStrip

                        Spacer(minLength: 10)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 30)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill").foregroundColor(Theme.ink)
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { showAbout = true } label: {
                        Image(systemName: "questionmark.circle").foregroundColor(Theme.ink)
                    }
                }
            }
            .fullScreenCover(isPresented: $showDaily) {
                GameContainer(kind: .daily)
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showAbout) { AboutView() }
        }
    }

    var streakCard: some View {
        HStack(spacing: 0) {
            streakStat("\(data.currentStreak)", "STREAK", "flame.fill", Theme.red)
            divider
            streakStat("\(data.bestStreak)", "BEST", "trophy.fill", Theme.amber)
            divider
            streakStat("\(foundCount)", "FOUND", "globe.americas.fill", Theme.green)
        }
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.4))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1.5)))
    }

    func streakStat(_ v: String, _ l: String, _ icon: String, _ color: Color) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 16)).foregroundColor(color)
            Text(v).font(.custom("Georgia", size: 22)).fontWeight(.semibold).foregroundColor(Theme.ink)
            Text(l).font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.5).foregroundColor(Theme.inkSoft)
        }
        .frame(maxWidth: .infinity)
    }

    var divider: some View { Rectangle().fill(Theme.line).frame(width: 1, height: 44) }

    var dailyCard: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("DAILY CHALLENGE")
                        .font(.system(size: 12, weight: .bold, design: .monospaced)).tracking(1)
                        .foregroundColor(Theme.inkSoft)
                    Text(todayString)
                        .font(.custom("Georgia", size: 20)).fontWeight(.semibold)
                        .foregroundColor(Theme.ink)
                }
                Spacer()
                if data.todayCompleted {
                    Image(systemName: data.todayWon ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .font(.system(size: 28))
                        .foregroundColor(data.todayWon ? Theme.green : Theme.red)
                }
            }
            Button(action: { showDaily = true }) {
                Text(data.todayCompleted ? "View today's result" : "Play today's puzzle")
                    .font(.custom("Georgia", size: 17)).fontWeight(.semibold)
                    .foregroundColor(Theme.paper)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(data.todayCompleted ? Theme.inkSoft : Theme.ink))
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.4))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1.5))
            .shadow(color: Theme.ink.opacity(0.12), radius: 0, x: 3, y: 3))
    }

    var statStrip: some View {
        let s = data.stats
        return VStack(spacing: 10) {
            Text("RANKED STATS")
                .font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(1)
                .foregroundColor(Theme.inkSoft)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                mini("\(s.totalGames)", "PLAYED")
                divider
                mini(String(format: "%.0f%%", s.winRate), "WIN RATE")
                divider
                mini(s.wins > 0 ? String(format: "%.1f", s.averageGuesses) : "—", "AVG")
            }
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.4))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1.5)))
        }
    }

    func mini(_ v: String, _ l: String) -> some View {
        VStack(spacing: 4) {
            Text(v).font(.custom("Georgia", size: 20)).fontWeight(.semibold).foregroundColor(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(l).font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.5).foregroundColor(Theme.inkSoft)
        }
        .frame(maxWidth: .infinity)
    }

    var todayString: String {
        let f = DateFormatter(); f.dateFormat = "MMMM d, yyyy"; return f.string(from: Date())
    }
}

// MARK: - Unlimited Tab (mode picker + play)

struct UnlimitedTab: View {
    @State private var ranked = true
    @State private var difficulty: Difficulty = .world
    @State private var play = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.paper.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 22) {
                        VStack(spacing: 6) {
                            Image(systemName: "infinity").font(.system(size: 40)).foregroundColor(Theme.ink)
                            Text("Unlimited")
                                .font(.custom("Georgia", size: 32)).fontWeight(.black).foregroundColor(Theme.ink)
                            Text("Play as many puzzles as you like")
                                .font(.system(size: 13, design: .monospaced)).foregroundColor(Theme.inkSoft)
                        }
                        .padding(.top, 16)

                        // Difficulty
                        VStack(alignment: .leading, spacing: 10) {
                            Text("DIFFICULTY")
                                .font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(1)
                                .foregroundColor(Theme.inkSoft)
                            ForEach(Difficulty.allCases, id: \.self) { d in
                                selectRow(title: d.label, blurb: d.blurb,
                                          selected: difficulty == d) { difficulty = d }
                            }
                        }

                        // Ranked vs practice
                        VStack(alignment: .leading, spacing: 10) {
                            Text("MODE")
                                .font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(1)
                                .foregroundColor(Theme.inkSoft)
                            selectRow(title: "Ranked", blurb: "Counts toward your stats",
                                      selected: ranked) { ranked = true }
                            selectRow(title: "Practice", blurb: "Free play — won't affect stats",
                                      selected: !ranked) { ranked = false }
                        }

                        Button(action: { play = true }) {
                            Text("Start")
                                .font(.custom("Georgia", size: 18)).fontWeight(.semibold)
                                .foregroundColor(Theme.paper)
                                .frame(maxWidth: .infinity).padding(.vertical, 15)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.ink))
                        }
                        .padding(.top, 4)
                    }
                    .padding(.horizontal, 20).padding(.bottom, 30)
                }
            }
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $play) {
                GameContainer(kind: .unlimited(ranked: ranked, difficulty: difficulty))
            }
        }
    }

    func selectRow(title: String, blurb: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 20)).foregroundColor(selected ? Theme.green : Theme.line)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.custom("Georgia", size: 17)).fontWeight(.semibold).foregroundColor(Theme.ink)
                    Text(blurb).font(.system(size: 12, design: .monospaced)).foregroundColor(Theme.inkSoft)
                }
                Spacer()
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Color.white.opacity(0.55) : Color.white.opacity(0.3))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? Theme.green : Theme.line, lineWidth: 1.5)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var data: AppDataManager
    @Environment(\.dismiss) var dismiss
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.paper.ignoresSafeArea()
                List {
                    Section {
                        Toggle(isOn: $settings.hapticsOn) {
                            Label("Haptics", systemImage: "iphone.radiowaves.left.and.right")
                        }
                        Toggle(isOn: $settings.soundOn) {
                            Label("Sound effects", systemImage: "speaker.wave.2.fill")
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.4))
                    .tint(Theme.green)

                    Section("Data") {
                        Label("Progress syncs across your devices via iCloud", systemImage: "icloud.fill")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.inkSoft)
                        Button(role: .destructive) { confirmClear = true } label: {
                            Label("Reset all progress", systemImage: "trash")
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.4))
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundColor(Theme.ink)
                }
            }
            .alert("Reset everything?", isPresented: $confirmClear) {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) { data.clearHistory() }
            } message: {
                Text("This permanently deletes your stats, streak, and trophy progress.")
            }
        }
    }
}

// MARK: - Game Container

enum GameKind {
    case daily
    case unlimited(ranked: Bool, difficulty: Difficulty)
}

struct GameContainer: View {
    let kind: GameKind
    @EnvironmentObject var data: AppDataManager
    @EnvironmentObject var settings: Settings
    @Environment(\.dismiss) var dismiss
    @StateObject private var vm = GameViewModel()
    @State private var started = false
    @State private var savedThisGame = false
    @State private var alreadyDoneDaily = false

    var body: some View {
        GameView(vm: vm, onClose: { dismiss() })
            .environmentObject(data)
            .environmentObject(settings)
            .onAppear {
                guard !started else { return }
                started = true
                switch kind {
                case .daily:
                    // If today's daily already played, show it as finished.
                    if let rec = data.dailyRecord() {
                        vm.startDaily()
                        replay(rec)
                        alreadyDoneDaily = true
                    } else {
                        vm.startDaily()
                    }
                case .unlimited(let ranked, let diff):
                    vm.startUnlimited(ranked: ranked, difficulty: diff)
                }
            }
            .onChange(of: vm.gameOver) { over in
                guard over, !savedThisGame, !alreadyDoneDaily else { return }
                savedThisGame = true
                data.saveGame(country: vm.secret,
                              guesses: vm.won ? vm.guesses.count : -1,
                              won: vm.won, mode: vm.mode,
                              ranked: vm.ranked, difficulty: vm.difficulty)
            }
    }

    // Reconstruct a finished daily so the player sees the answer, not a fresh board.
    private func replay(_ rec: GameRecord) {
        vm.gameOver = true
        vm.won = rec.won
    }
}

// MARK: - Game View

struct GameView: View {
    @ObservedObject var vm: GameViewModel
    var onClose: () -> Void
    @EnvironmentObject var data: AppDataManager
    @EnvironmentObject var settings: Settings
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Theme.paper.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    header
                    rule
                    if !vm.gameOver {
                        inputSection
                        if !vm.filteredCountries.isEmpty && focused && !vm.searchText.isEmpty {
                            autocomplete
                        }
                        metaBar
                    }
                    banner
                    guessList
                }
                .padding(.horizontal, 16).padding(.bottom, 60)
            }
            if vm.showFlagOverlay { flagOverlay }
        }
    }

    var header: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.ink).padding(8)
            }
            Spacer()
            VStack(spacing: 1) {
                Text(modeTitle)
                    .font(.custom("Georgia", size: 22)).fontWeight(.black).foregroundColor(Theme.ink)
                Text(modeSub)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.inkSoft)
            }
            Spacer()
            Color.clear.frame(width: 33)
        }
        .padding(.vertical, 12)
    }

    var modeTitle: String { vm.mode == .daily ? "DAILY" : "ATLASLE" }
    var modeSub: String {
        if vm.mode == .daily { return "one puzzle for everyone" }
        return "\(vm.difficulty.label.uppercased()) · \(vm.ranked ? "RANKED" : "PRACTICE")"
    }

    var rule: some View {
        Rectangle().fill(Theme.ink.opacity(0.35)).frame(height: 1.5).padding(.vertical, 12)
    }

    var inputSection: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                TextField("Type a country…", text: $vm.searchText)
                    .font(.system(size: 17, design: .monospaced)).padding(14)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.55))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.ink, lineWidth: 2)))
                    .foregroundColor(Theme.ink)
                    .focused($focused).submitLabel(.go)
                    .onSubmit { vm.submitGuess(soundOn: settings.soundOn, hapticsOn: settings.hapticsOn) }
                    .autocorrectionDisabled()
                Button(action: {
                    focused = false
                    vm.submitGuess(soundOn: settings.soundOn, hapticsOn: settings.hapticsOn)
                }) {
                    Text("Guess").font(.custom("Georgia", size: 16)).fontWeight(.semibold)
                        .foregroundColor(Theme.paper).padding(.horizontal, 22)
                        .frame(maxHeight: .infinity)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.ink))
                }
                .frame(height: 50)
            }
            .frame(height: 50)
            if !vm.errorMessage.isEmpty {
                Text(vm.errorMessage).font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.red).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 2)
            }
        }
        .padding(.bottom, 8)
    }

    var autocomplete: some View {
        VStack(spacing: 0) {
            ForEach(vm.filteredCountries) { c in
                Button(action: { vm.searchText = c.name; focused = false }) {
                    HStack(spacing: 10) {
                        Text(c.code).font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .tracking(1).foregroundColor(Theme.inkSoft).frame(width: 40, alignment: .leading)
                        Text(c.name).font(.system(size: 15, design: .monospaced)).foregroundColor(Theme.ink)
                        Spacer()
                        Text(c.flag).font(.system(size: 20))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 11).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if c.id != vm.filteredCountries.last?.id { Theme.line.frame(height: 0.5) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.ink, lineWidth: 2))
            .shadow(color: Theme.ink.opacity(0.15), radius: 6, x: 0, y: 3))
        .padding(.top, 6)
    }

    var metaBar: some View {
        HStack {
            Text("GUESS \(vm.guessNumber) OF \(vm.maxGuesses)")
                .font(.system(size: 12.5, weight: .medium, design: .monospaced)).tracking(1)
                .foregroundColor(Theme.inkSoft)
            Spacer()
            Button("GIVE UP") { vm.giveUp() }
                .font(.system(size: 12.5, design: .monospaced)).foregroundColor(Theme.inkSoft).underline()
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder var banner: some View {
        if vm.gameOver {
            ResultBanner(vm: vm, onPlayAgain: vm.mode == .daily ? nil : { vm.newGameSameSettings() })
        }
    }

    var guessList: some View {
        LazyVStack(spacing: 12) {
            ForEach(vm.guesses) { g in
                GuessCardView(guess: g) { vm.showFlag(emoji: g.country.flag, name: g.country.name) }
                    .transition(.asymmetric(insertion: .scale(scale: 0.95).combined(with: .opacity), removal: .opacity))
            }
        }
    }

    var flagOverlay: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
                .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { vm.showFlagOverlay = false } }
            VStack(spacing: 10) {
                Text(vm.overlayFlag).font(.system(size: 96))
                Text(vm.overlayName).font(.custom("Georgia", size: 20)).fontWeight(.semibold).foregroundColor(Theme.ink)
                Text("TAP ANYWHERE TO CLOSE").font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(1).foregroundColor(Theme.inkSoft).padding(.top, 4)
            }
            .padding(.horizontal, 36).padding(.vertical, 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.paper)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.ink, lineWidth: 2))
                .shadow(color: Theme.ink.opacity(0.35), radius: 0, x: 6, y: 6))
            .scaleEffect(vm.showFlagOverlay ? 1 : 0.75).opacity(vm.showFlagOverlay ? 1 : 0)
        }
    }
}

// MARK: - Result Banner (+ share)

struct ResultBanner: View {
    @ObservedObject var vm: GameViewModel
    var onPlayAgain: (() -> Void)?
    @State private var showInfo = false
    @State private var showShare = false

    var body: some View {
        VStack(spacing: 6) {
            Text(vm.won ? "You found it!" : "Out of guesses")
                .font(.custom("Georgia", size: 28)).fontWeight(.black).foregroundColor(Theme.ink)
            Text(vm.won
                 ? "Solved in \(vm.guesses.count) \(vm.guesses.count == 1 ? "guess" : "guesses")."
                 : "The secret country was")
                .font(.system(size: 14, design: .monospaced)).foregroundColor(Theme.inkSoft)

            Button { vm.showFlag(emoji: vm.secret.flag, name: vm.secret.name) } label: {
                HStack(spacing: 6) {
                    Text(vm.secret.flag).font(.system(size: 24))
                    Text(vm.secret.name).font(.custom("Georgia", size: 19)).italic().foregroundColor(Theme.ink)
                }
            }
            .padding(.top, 4)

            HStack(spacing: 10) {
                Button(action: { withAnimation { showInfo.toggle() } }) {
                    Text(showInfo ? "ⓘ Hide" : "ⓘ Details")
                        .font(.system(size: 12.5, design: .monospaced)).foregroundColor(Theme.ink)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.ink, lineWidth: 1.5))
                }
                Button(action: { showShare = true }) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.system(size: 12.5, design: .monospaced)).foregroundColor(Theme.ink)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.ink, lineWidth: 1.5))
                }
            }
            .padding(.top, 8)

            if showInfo { infoPanel.transition(.opacity.combined(with: .move(edge: .top))) }

            if let again = onPlayAgain {
                Button(action: again) {
                    Text("Play again").font(.custom("Georgia", size: 15)).fontWeight(.semibold)
                        .foregroundColor(Theme.paper).padding(.horizontal, 28).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.ink))
                }
                .padding(.top, 12)
            } else {
                Text("Come back tomorrow for a new puzzle")
                    .font(.system(size: 12, design: .monospaced)).italic().foregroundColor(Theme.inkSoft)
                    .padding(.top, 12)
            }
        }
        .padding(22).frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 5).fill(vm.won ? Theme.greenBg : Theme.redBg)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.ink, lineWidth: 2))
            .shadow(color: Theme.ink.opacity(0.18), radius: 0, x: 4, y: 4))
        .padding(.bottom, 16)
        .transition(.scale(scale: 0.95).combined(with: .opacity))
        .sheet(isPresented: $showShare) {
            ShareSheet(items: [shareText])
        }
    }

    var shareText: String {
        let header = vm.mode == .daily ? "Atlasle Daily — \(AppDataManager.dayKey())" : "Atlasle"
        let score = vm.won ? "\(vm.guesses.count)/8" : "X/8"
        // Emoji grid: oldest guess first, each row = that guess's clue accuracies.
        let rows = vm.guesses.reversed().map { g in
            g.clues.map { c -> String in
                switch c.accuracy { case .exact: return "🟩"; case .close: return "🟨"; case .far: return "🟥" }
            }.joined()
        }.joined(separator: "\n")
        return "\(header) \(score)\n\(rows)"
    }

    var infoPanel: some View {
        VStack(spacing: 0) {
            row("Continent", vm.secret.continent)
            row("Starts with", String(vm.secret.name.prefix(1)).uppercased())
            row("Size", GameViewModel.fmtArea(vm.secret.area) + " mi²")
            row("Population", GameViewModel.fmtPop(vm.secret.population))
            row("Economy (GDP)", GameViewModel.fmtGdp(vm.secret.gdp))
            row("Government", vm.secret.government)
            row("Language", vm.secret.language)
            row("Flag colors", vm.secret.colors.joined(separator: ", "))
        }
        .padding(.vertical, 6).padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.45))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line, lineWidth: 1.5)))
        .padding(.top, 8)
    }

    func row(_ l: String, _ v: String) -> some View {
        HStack {
            Text(l.uppercased()).font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(0.5).foregroundColor(Theme.inkSoft)
            Spacer()
            Text(v).font(.custom("Georgia", size: 13)).fontWeight(.semibold)
                .foregroundColor(Theme.ink).multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 0.5).padding(.leading, 4) }
    }
}

// MARK: - Share Sheet wrapper

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - Guess Card & Clue Cell

struct GuessCardView: View {
    let guess: GuessResult
    let onFlagTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button(action: onFlagTap) { Text(guess.country.flag).font(.system(size: 24)) }
                    .buttonStyle(.plain)
                Text(guess.country.name).font(.custom("Georgia", size: 20)).fontWeight(.semibold)
                    .foregroundColor(Theme.ink)
            }
            let cols = Array(repeating: GridItem(.flexible(), spacing: 7), count: 4)
            LazyVGrid(columns: cols, spacing: 7) {
                ForEach(guess.clues, id: \.label) { ClueCell(clue: $0) }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.4))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line, lineWidth: 1.5))
            .shadow(color: Theme.ink.opacity(0.18), radius: 0, x: 2, y: 2))
    }
}

struct ClueCell: View {
    let clue: ClueResult
    var body: some View {
        VStack(spacing: 2) {
            Text(clue.label.uppercased()).font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .tracking(0.5).opacity(0.75)
            Text(clue.value).font(.system(size: 12, weight: .bold, design: .monospaced))
                .lineLimit(2).minimumScaleFactor(0.7).multilineTextAlignment(.center)
            if !clue.subtitle.isEmpty {
                Text(clue.subtitle).font(.system(size: 9.5, design: .monospaced)).opacity(0.8)
            }
        }
        .foregroundColor(Theme.fg(for: clue.accuracy))
        .frame(maxWidth: .infinity).frame(minHeight: 58)
        .padding(.horizontal, 3).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.bg(for: clue.accuracy))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.fg(for: clue.accuracy), lineWidth: 1.5)))
    }
}

// MARK: - World Map Tab

struct MapTabView: View {
    @EnvironmentObject var data: AppDataManager
    @State private var selected: Country?
    let all = GameViewModel.everything

    var foundCodes: Set<String> {
        Set(data.gameHistory.filter { $0.won }.map { $0.countryCode })
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.paper.ignoresSafeArea()
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("WORLD MAP")
                                .font(.custom("Georgia", size: 22)).fontWeight(.black).tracking(2)
                                .foregroundColor(Theme.ink)
                            Text("\(foundCodes.count) of \(all.count) countries found")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(Theme.inkSoft)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)

                    // Pan/zoomable map
                    WorldMapView(all: all, foundCodes: foundCodes, selected: $selected)

                    // Continent legend
                    legend.padding(.vertical, 10)
                }
            }
            .sheet(item: $selected) { CountryDetailView(country: $0) }
        }
    }

    var legend: some View {
        let conts = ["Africa","Asia","Europe","North America","South America","Oceania"]
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(conts, id: \.self) { c in
                    HStack(spacing: 5) {
                        Circle().fill(Theme.continentColor(c)).frame(width: 11, height: 11)
                        Text(c).font(.system(size: 11, design: .monospaced)).foregroundColor(Theme.inkSoft)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

// Equirectangular projection of dots on a soft world backdrop, with pinch-zoom & pan.
struct WorldMapView: View {
    let all: [Country]
    let foundCodes: Set<String>
    @Binding var selected: Country?

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 10

    func project(_ c: Country, in size: CGSize) -> CGPoint {
        let x = (c.lon + 180) / 360 * size.width
        let y = (90 - c.lat) / 180 * size.height
        return CGPoint(x: x, y: y)
    }

    // Keep the scaled map from being dragged off-screen.
    private func clampedOffset(_ proposed: CGSize, viewport: CGSize, canvas: CGSize) -> CGSize {
        let scaledW = canvas.width * scale
        let scaledH = canvas.height * scale
        let maxX = max(0, (scaledW - viewport.width) / 2)
        let maxY = max(0, (scaledH - viewport.height) / 2)
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }

    private func zoom(by factor: CGFloat, viewport: CGSize, canvas: CGSize) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            scale = min(max(scale * factor, minScale), maxScale)
            lastScale = scale
            offset = clampedOffset(offset, viewport: viewport, canvas: canvas)
            lastOffset = offset
        }
    }

    private func reset() {
        withAnimation(.spring) {
            scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero
        }
    }

    var body: some View {
        GeometryReader { geo in
            let viewport = geo.size
            let w = viewport.width
            let h = w / 2
            let canvas = CGSize(width: w, height: h)
            // Show country labels once zoomed in enough to be readable.
            let showLabels = scale >= 3.5

            ZStack {
                ZStack {
                    MapBackdrop()
                        .frame(width: w, height: h)

                    ForEach(all) { c in
                        let p = project(c, in: canvas)
                        let found = foundCodes.contains(c.code)
                        ZStack {
                            Circle()
                                .fill(found ? Theme.continentColor(c.continent) : Theme.line.opacity(0.5))
                                .frame(width: found ? 7 : 4, height: found ? 7 : 4)
                                .overlay(Circle().stroke(found ? Theme.ink.opacity(0.5) : .clear, lineWidth: 0.5))
                            if showLabels && found {
                                Text(c.name)
                                    .font(.system(size: 7, weight: .semibold, design: .monospaced))
                                    .foregroundColor(Theme.ink)
                                    .fixedSize()
                                    .scaleEffect(1 / scale)   // counter-scale so text stays legible
                                    .offset(y: -7 / scale)
                            }
                        }
                        .position(p)
                        .onTapGesture { selected = c }
                    }
                }
                .frame(width: w, height: h)
                .scaleEffect(scale)
                .offset(offset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.continentColor("North America").opacity(0.04)))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1.5))
                .contentShape(Rectangle())
                .gesture(
                    SimultaneousGesture(
                        MagnificationGesture()
                            .onChanged { v in scale = min(max(lastScale * v, minScale), maxScale) }
                            .onEnded { _ in
                                lastScale = scale
                                offset = clampedOffset(offset, viewport: viewport, canvas: canvas)
                                lastOffset = offset
                            },
                        DragGesture()
                            .onChanged { v in
                                let proposed = CGSize(width: lastOffset.width + v.translation.width,
                                                      height: lastOffset.height + v.translation.height)
                                offset = clampedOffset(proposed, viewport: viewport, canvas: canvas)
                            }
                            .onEnded { _ in lastOffset = offset }
                    )
                )
                .onTapGesture(count: 2) { reset() }

                // Zoom controls
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        VStack(spacing: 1) {
                            zoomButton("plus") { zoom(by: 1.6, viewport: viewport, canvas: canvas) }
                            Divider().frame(width: 28)
                            zoomButton("minus") { zoom(by: 1/1.6, viewport: viewport, canvas: canvas) }
                            if scale > 1.01 {
                                Divider().frame(width: 28)
                                zoomButton("arrow.counterclockwise") { reset() }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.paper)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1.5))
                            .shadow(color: Theme.ink.opacity(0.15), radius: 3, x: 0, y: 2))
                        .padding(12)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
    }

    func zoomButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.ink)
                .frame(width: 36, height: 36)
        }
    }
}

// Soft equirectangular backdrop: ocean fill, latitude/longitude lines, equator emphasis.
struct MapBackdrop: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(red: 0.78, green: 0.86, blue: 0.85).opacity(0.35)) // soft sea
                Path { p in
                    // longitude lines every 30°
                    for i in stride(from: 0, through: 12, by: 1) {
                        let x = CGFloat(i)/12 * w
                        p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
                    }
                    // latitude lines every 30°
                    for j in stride(from: 0, through: 6, by: 1) {
                        let y = CGFloat(j)/6 * h
                        p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                    }
                }
                .stroke(Theme.line.opacity(0.4), lineWidth: 0.5)
                // Equator
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h/2)); p.addLine(to: CGPoint(x: w, y: h/2))
                }
                .stroke(Theme.inkSoft.opacity(0.4), lineWidth: 1)
            }
        }
    }
}

// MARK: - Trophy Room

struct TrophyRoomView: View {
    @EnvironmentObject var data: AppDataManager
    @State private var selected: Country?
    let countries = GameViewModel.everything
    let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.paper.ignoresSafeArea()
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("TROPHY ROOM")
                                .font(.custom("Georgia", size: 22)).fontWeight(.black).tracking(2)
                                .foregroundColor(Theme.ink)
                            Text("\(data.gameHistory.filter { $0.won }.map { $0.countryCode }.reduce(into: Set<String>()) { $0.insert($1) }.count) of \(countries.count) found")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(Theme.inkSoft)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    Divider().padding(.bottom, 4)
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(countries) { c in
                                let wins = data.winCount(c.code)
                                Button(action: { selected = c }) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(wins > 0 ? Theme.greenBg : Color.white.opacity(0.3))
                                            .overlay(RoundedRectangle(cornerRadius: 8)
                                                .stroke(wins > 0 ? Theme.green : Theme.line, lineWidth: 1.5))
                                        VStack(spacing: 2) {
                                            Text(c.flag).font(.system(size: 24))
                                            if wins > 0 {
                                                HStack(spacing: 1) {
                                                    Image(systemName: "star.fill").font(.system(size: 9))
                                                        .foregroundColor(Theme.green)
                                                    if wins > 1 {
                                                        Text("×\(wins)").font(.system(size: 9, weight: .bold, design: .monospaced))
                                                            .foregroundColor(Theme.green)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    .aspectRatio(1, contentMode: .fill)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(12)
                    }
                }
            }
            .sheet(item: $selected) { CountryDetailView(country: $0) }
        }
    }
}

struct CountryDetailView: View {
    let country: Country
    @EnvironmentObject var data: AppDataManager
    @Environment(\.dismiss) var dismiss

    var wins: [GameRecord] { data.gameHistory.filter { $0.countryCode == country.code && $0.won } }
    var best: Int? { wins.map { $0.guesses }.min() }

    var body: some View {
        ZStack {
            Theme.paper.ignoresSafeArea()
            VStack(spacing: 20) {
                HStack {
                    Text(country.name).font(.custom("Georgia", size: 24)).fontWeight(.semibold).foregroundColor(Theme.ink)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 24)).foregroundColor(Theme.inkSoft)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 20)

                HStack(spacing: 20) {
                    Text(country.flag).font(.system(size: 64))
                    VStack(alignment: .leading, spacing: 8) {
                        if !wins.isEmpty {
                            HStack(spacing: 3) {
                                ForEach(0..<min(wins.count, 8), id: \.self) { _ in
                                    Image(systemName: "star.fill").font(.system(size: 13)).foregroundColor(Theme.green)
                                }
                                if wins.count > 8 {
                                    Text("+\(wins.count - 8)").font(.system(size: 12, weight: .bold, design: .monospaced))
                                        .foregroundColor(Theme.green)
                                }
                            }
                            Text("Found \(wins.count) \(wins.count == 1 ? "time" : "times")")
                                .font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundColor(Theme.green)
                            if let b = best {
                                Text("Best: \(b) \(b == 1 ? "guess" : "guesses")")
                                    .font(.system(size: 11, design: .monospaced)).foregroundColor(Theme.inkSoft)
                            }
                        } else {
                            Text("Not yet found")
                                .font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundColor(Theme.red)
                        }
                    }
                }
                .padding(.horizontal, 20)

                detail("Continent", country.continent)
                detail("Population", GameViewModel.fmtPop(country.population))
                detail("Size", GameViewModel.fmtArea(country.area) + " mi²")
                detail("Economy (GDP)", GameViewModel.fmtGdp(country.gdp))
                detail("Government", country.government)
                detail("Language", country.language)
                detail("Flag Colors", country.colors.joined(separator: ", "))
                Spacer()
            }
        }
    }

    func detail(_ l: String, _ v: String) -> some View {
        HStack {
            Text(l.uppercased()).font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(0.5).foregroundColor(Theme.inkSoft)
            Spacer()
            Text(v).font(.system(size: 13, design: .monospaced)).foregroundColor(Theme.ink)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }
}

// MARK: - Stats

struct StatsView: View {
    @EnvironmentObject var data: AppDataManager
    let all = GameViewModel.everything

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.paper.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("STATISTICS").font(.custom("Georgia", size: 22)).fontWeight(.black)
                                    .tracking(2).foregroundColor(Theme.ink)
                                Text("ranked games only").font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundColor(Theme.inkSoft)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16).padding(.top, 12)

                        grid.padding(.horizontal, 16)

                        if data.stats.totalGames > 0 { distribution }
                        continentMastery
                        if !data.gameHistory.isEmpty { recent }
                        Spacer(minLength: 20)
                    }
                    .padding(.bottom, 40)
                }
            }
        }
    }

    var grid: some View {
        let s = data.stats
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                box("\(s.totalGames)", "PLAYED", Theme.ink)
                box("\(s.wins)", "WINS", Theme.green)
            }
            HStack(spacing: 10) {
                box(String(format: "%.0f%%", s.winRate), "WIN RATE", Theme.amber)
                box(s.wins > 0 ? String(format: "%.1f", s.averageGuesses) : "—", "AVG GUESS", Theme.inkSoft)
            }
            HStack(spacing: 10) {
                box("\(data.currentStreak)", "STREAK", Theme.red)
                box("\(data.bestStreak)", "BEST STREAK", Theme.amber)
            }
        }
    }

    func box(_ v: String, _ l: String, _ c: Color) -> some View {
        VStack(spacing: 6) {
            Text(v).font(.custom("Georgia", size: 28)).fontWeight(.semibold).foregroundColor(c)
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(l).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(0.5).foregroundColor(Theme.inkSoft)
        }
        .frame(maxWidth: .infinity).padding(14)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.4))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line, lineWidth: 1.5)))
    }

    var distribution: some View {
        VStack(spacing: 12) {
            label("GUESS DISTRIBUTION")
            VStack(spacing: 6) {
                ForEach(1...8, id: \.self) { g in
                    let count = data.stats.distribution[g] ?? 0
                    let maxC = max(data.rankedGames.filter { $0.won }.count,
                                   data.stats.distribution[-1] ?? 0, 1)
                    bar(label: "\(g)", count: count, maxC: maxC, color: Theme.green)
                }
                Divider().padding(.vertical, 4)
                bar(label: "✕", count: data.stats.distribution[-1] ?? 0,
                    maxC: max(data.rankedGames.filter { $0.won }.count, data.stats.distribution[-1] ?? 0, 1),
                    color: Theme.red)
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.4))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line, lineWidth: 1.5)))
        .padding(.horizontal, 16)
    }

    func bar(label: String, count: Int, maxC: Int, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(label == "✕" ? Theme.red : Theme.ink).frame(width: 24)
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 4).fill(color)
                    .frame(width: max(CGFloat(count)/CGFloat(maxC) * geo.size.width, count > 0 ? 18 : 0))
            }
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.3)))
            Text("\(count)").font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.ink).frame(width: 30, alignment: .trailing)
        }
    }

    var continentMastery: some View {
        VStack(spacing: 12) {
            label("CONTINENT MASTERY")
            VStack(spacing: 10) {
                ForEach(data.continentMastery(all), id: \.continent) { item in
                    let pct = item.total > 0 ? Double(item.found)/Double(item.total) : 0
                    VStack(spacing: 4) {
                        HStack {
                            HStack(spacing: 6) {
                                Circle().fill(Theme.continentColor(item.continent)).frame(width: 10, height: 10)
                                Text(item.continent).font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundColor(Theme.ink)
                            }
                            Spacer()
                            Text("\(item.found)/\(item.total)")
                                .font(.system(size: 12, design: .monospaced)).foregroundColor(Theme.inkSoft)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.4))
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Theme.continentColor(item.continent))
                                    .frame(width: max(CGFloat(pct) * geo.size.width, item.found > 0 ? 6 : 0))
                            }
                        }
                        .frame(height: 10)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.4))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line, lineWidth: 1.5)))
        .padding(.horizontal, 16)
    }

    var recent: some View {
        VStack(spacing: 12) {
            label("RECENT GAMES")
            VStack(spacing: 6) {
                ForEach(data.gameHistory.prefix(10)) { r in
                    HStack(spacing: 10) {
                        Text(r.countryFlag).font(.system(size: 18))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(r.countryName).font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    .foregroundColor(Theme.ink)
                                Text(r.mode == .daily ? "DAILY" : (r.ranked ? r.difficulty.label.uppercased() : "PRACTICE"))
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(Theme.line.opacity(0.5)))
                                    .foregroundColor(Theme.inkSoft)
                            }
                            Text(dateStr(r.date)).font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.inkSoft)
                        }
                        Spacer()
                        if r.won {
                            Text("\(r.guesses)").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundColor(Theme.green)
                        } else {
                            Text("Failed").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(Theme.red)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.3)))
                }
            }
        }
        .padding(.horizontal, 16)
    }

    func label(_ t: String) -> some View {
        Text(t).font(.system(size: 12, weight: .bold, design: .monospaced)).tracking(1)
            .foregroundColor(Theme.inkSoft).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
    }

    func dateStr(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"; return f.string(from: d)
    }
}

// MARK: - About

struct AboutView: View {
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            ZStack {
                Theme.paper.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        section("How to Play",
                                "Guess the secret country in 8 tries. Each guess reveals clues comparing it to the answer.")
                        VStack(alignment: .leading, spacing: 8) {
                            head("The Clues")
                            clue("Continent", "Same continent?")
                            clue("Letter", "First letter of the name")
                            clue("Size", "Land area off (↑ bigger / ↓ smaller)")
                            clue("Population", "People off (↑ more / ↓ fewer)")
                            clue("Economy", "GDP off (↑ richer / ↓ poorer)")
                            clue("Government", "Type of government")
                            clue("Language", "Most spoken language")
                            clue("Flag", "% of flag colors that match")
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            head("Colors")
                            legend(Theme.green, "Exact match")
                            legend(Theme.amber, "Close — within 25%")
                            legend(Theme.red, "Far off")
                        }
                        section("Modes",
                                "Daily is one shared puzzle per day — win consecutive days to build a streak. Unlimited lets you play freely with Easy or World difficulty; Practice mode won't touch your stats.")
                        Spacer(minLength: 20)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("About").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }.foregroundColor(Theme.ink) } }
        }
    }
    func section(_ t: String, _ b: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { head(t)
            Text(b).font(.system(size: 13.5, design: .monospaced)).foregroundColor(Theme.inkSoft).lineSpacing(2) }
    }
    func head(_ t: String) -> some View {
        Text(t).font(.custom("Georgia", size: 17)).fontWeight(.semibold).foregroundColor(Theme.ink)
    }
    func clue(_ l: String, _ d: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(l).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundColor(Theme.green)
                .frame(width: 84, alignment: .leading)
            Text(d).font(.system(size: 13, design: .monospaced)).foregroundColor(Theme.inkSoft)
        }
    }
    func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 12) {
            Circle().fill(c).frame(width: 12, height: 12)
            Text(t).font(.system(size: 13, design: .monospaced)).foregroundColor(Theme.ink)
        }
    }
}


//
//  newfile.swift
//  Atlasle
//
//  Created by Sesh Sudarshan on 6/1/26.
//

