import Foundation
import Testing
@testable import MenuScores

struct NBAAnswerMarkdownTests {
    private func answer(_ text: String, citations: [NBAReviewAnswer.Citation] = []) -> NBAReviewAnswer {
        .init(gameID:"401909901",text:text,sources:[],citations:citations,generatedAt:Date(),requestID:nil,responseID:nil,usage:nil,searched:false)
    }
    @Test func actualChinesePunctuationBoundaryAndTrailingSpaceBothRenderWithoutChangingSentence() {
        for text in ["**不是垃圾时间刷分，但也不是靠最后一球独自决定胜负。**文班亚马全场43分。", "**不是垃圾时间刷分，但也不是靠最后一球独自决定胜负。 **文班亚马全场43分。"] {
            let result = answer(text).formattedText
            #expect(String(result.characters) == "不是垃圾时间刷分，但也不是靠最后一球独自决定胜负。文班亚马全场43分。")
            #expect(result.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
            #expect(answer(text).text == text)
        }
    }
    @Test func normalBoldItalicParagraphsAndMixedListsKeepTheirHierarchy() {
        let blocks = NBAAnswerMarkdown.blocks(answer("### 克制标题\n\n第一段**重点**和*斜体*。\n\n- 文班3分\n- 福克斯2分\n1. 第一项\n2) 第二项\n三、第三项"))
        #expect(blocks.map(\.kind) == [.heading,.paragraph,.bullet,.bullet,.ordered("1."),.ordered("2."),.ordered("三、")])
        #expect(blocks[1].text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(blocks[1].text.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
        #expect(String(blocks[2].text.characters) == "文班3分")
    }
    @Test func literalStarsMathAndCodeAreNotBlindlyStripped() {
        let text = "纯文本星号 *，没有闭合。\n\n`**字面标记 **`与2 ** 3 ** 2。\n\n```text\n**不是粗体 **\n```"
        let blocks = NBAAnswerMarkdown.blocks(answer(text))
        #expect(String(blocks[0].text.characters).contains("星号 *"))
        #expect(String(blocks[1].text.characters).contains("**字面标记 **"))
        #expect(String(blocks[1].text.characters).contains("2 ** 3 ** 2"))
        #expect(blocks.last?.kind == .code)
        #expect(String(blocks.last!.text.characters) == "**不是粗体 **")
    }
    @Test func ordinaryPublicSourceLinksAndNativeCitationsRemainClickable() {
        let url = URL(string:"https://www.nba.com/news/report")!,source = "**根据官方。**说明[来源](https://www.nba.com/news/report)"
        let start = source.distance(from:source.startIndex,to:source.range(of:"[来源]")!.lowerBound)
        let citation = NBAReviewAnswer.Citation(start:start,end:source.count,url:url)
        let native = answer(source,citations:[citation]).formattedText
        #expect(String(native.characters) == "根据官方。说明来源")
        #expect(native.runs.contains { $0.link == url })
        let ordinary = answer("[比赛资料](https://site.api.espn.com/apis/site/v2/sports/basketball/nba/summary?event=401909901)").formattedText
        #expect(ordinary.runs.contains { $0.link?.host == "site.api.espn.com" })
    }
    @Test func dangerousSchemesPrivateDestinationsHTMLAndRemoteImagesAreNeverActive() {
        for raw in ["javascript:alert(1)","data:text/html,hello","file:///etc/passwd","https://www.nba.com@evil.example/path","https://127.0.0.1/path","https://nba.com.evil.example/path"] {
            #expect(!NBAAnswerMarkdown.safeLink(URL(string:raw)!))
        }
        let rendered = answer("![追踪图](https://tracker.example/pixel.png)\n\n<img src='https://tracker.example/pixel.png'>\n\n<script>alert(1)</script>\n\n[危险](file:///etc/passwd)").formattedText
        #expect(String(rendered.characters).contains("追踪图"))
        #expect(!rendered.runs.contains { $0.link != nil })
    }
    @Test func longLinksAndPlainTextKeepTheirCompleteContent() {
        let label = String(repeating:"球队官方资料",count:20)
        let value = answer("[\(label)](https://www.nba.com/news/very-long-official-report?ref=menuscores)").formattedText
        #expect(String(value.characters) == label)
        #expect(value.runs.contains { $0.link != nil })
        let plain = "Q4 2:40，118–107。没有符合clutch口径的回合。"
        #expect(String(answer(plain).formattedText.characters) == plain)
    }
}
