import Foundation

enum NBALocalization {
    private static let players = [
        "AK Okereke": "AK·奥克雷克",
        "Arthur Kaluma": "阿瑟·卡卢马", "Chris Manon": "克里斯·马农",
        "Jaden Hardy": "杰登·哈迪", "Jaren Jackson Jr.": "小贾伦·杰克逊",
        "Darryn Peterson": "达林·彼得森", "Brice Sensabaugh": "布莱斯·森萨博",
        "Svi Mykhailiuk": "斯维·米哈伊柳克", "Josh Okogie": "约什·奥科吉",
        "Josh Green": "约什·格林", "Blake Hinson": "布莱克·辛森",
        "Tony Bradley": "托尼·布拉德利", "Mo Bamba": "莫·班巴",
        "LeBron James": "勒布朗·詹姆斯", "Luka Doncic": "卢卡·东契奇",
        "Austin Reaves": "奥斯汀·里夫斯", "Rui Hachimura": "八村塁",
        "Deandre Ayton": "德安德烈·艾顿", "Marcus Smart": "马库斯·斯马特",
        "Jarred Vanderbilt": "贾里德·范德比尔特", "Gabe Vincent": "盖布·文森特",
        "Dalton Knecht": "道尔顿·克内克特", "Bronny James": "布朗尼·詹姆斯",
        "Jaxson Hayes": "贾克森·海斯", "Maxi Kleber": "马克西·克勒贝尔",
        "Ziaire Williams": "扎伊尔·威廉姆斯", "Walker Kessler": "沃克·凯斯勒",
        "Matisse Thybulle": "马蒂斯·塞布尔", "Kevon Looney": "凯文·卢尼",
        "Sandro Mamukelashvili": "桑德罗·马穆凯拉什维利", "Jake LaRavia": "杰克·拉拉维亚",
        "Collin Sexton": "科林·塞克斯顿", "Quentin Grimes": "昆廷·格兰姆斯",
        "Stephen Curry": "斯蒂芬·库里", "Kevin Durant": "凯文·杜兰特",
        "Jayson Tatum": "杰森·塔图姆", "Jaylen Brown": "杰伦·布朗",
        "Nikola Jokic": "尼古拉·约基奇", "Giannis Antetokounmpo": "扬尼斯·阿德托昆博",
        "Shai Gilgeous-Alexander": "谢伊·吉尔杰斯-亚历山大", "Victor Wembanyama": "维克托·文班亚马",
        "Anthony Davis": "安东尼·戴维斯", "Anthony Edwards": "安东尼·爱德华兹",
        "Donovan Mitchell": "多诺万·米切尔", "Jalen Brunson": "杰伦·布伦森",
        "James Harden": "詹姆斯·哈登", "Kawhi Leonard": "科怀·伦纳德",
        "Paul George": "保罗·乔治", "Julius Randle": "朱利叶斯·兰德尔",
        "Lauri Markkanen": "劳里·马尔卡宁", "Keyonte George": "基扬特·乔治",
        "Jusuf Nurkic": "优素福·努尔基奇", "Kyle Filipowski": "凯尔·菲利波夫斯基",
        "Isaiah Collier": "以赛亚·科利尔", "Ace Bailey": "埃斯·贝利"
    ]

    private static let officialPlayers: [String: String] = {
        guard let url = Bundle.main.url(forResource: "NBAPlayerNames.zh-Hans", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let names = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return names.reduce(into: [:]) { result, item in result[normalizedName(item.key)] = item.value }
    }()
    private static let knownPlayers = players.reduce(into: [String: String]()) { result, item in
        result[normalizedName(item.key)] = item.value
    }

    static func normalizedName(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            .filter { !["jr", "sr", "ii", "iii", "iv"].contains($0) }.joined(separator: " ")
    }

    static func player(_ name: String) -> String {
        let key = normalizedName(name)
        return knownPlayers[key] ?? officialPlayers[key] ?? name
    }
    static func position(_ value: String?) -> String {
        switch value {
        case "PG": return "控卫"
        case "SG": return "分卫"
        case "SF": return "小前锋"
        case "PF": return "大前锋"
        case "C": return "中锋"
        case "G": return "后卫"
        case "F": return "前锋"
        case "F-C", "C-F": return "锋线 / 中锋"
        case "G-F", "F-G": return "后卫 / 前锋"
        default: return ""
        }
    }
    static func absence(_ reason: String?) -> String {
        switch reason?.uppercased() {
        case "COACH'S DECISION": return "未出场 · 教练决定"
        case "INJURY", "INJURED": return "未出场 · 伤病"
        case "INACTIVE": return "未激活"
        case "SUSPENSION", "SUSPENDED": return "禁赛"
        default: return "未出场"
        }
    }
    static func status(state: String?, detail: String?, period: Int?, clock: String?) -> String {
        let detail = detail?.uppercased() ?? ""
        if detail.contains("POSTPON") { return "比赛延期" }
        if detail.contains("CANCEL") { return "比赛取消" }
        if detail.contains("HALFTIME") { return "中场休息" }
        switch state {
        case "post": return detail.contains("OT") ? "已结束 · 加时赛" : "已结束"
        case "pre": return "尚未开始"
        case "in":
            let section = (period ?? 1) > 4 ? "加时\((period ?? 5) - 4)" : "第\(period ?? 1)节"
            return "进行中 · \(section) \(clock ?? "")".trimmingCharacters(in: .whitespaces)
        default: return "等待比赛信息"
        }
    }
}
