import SwiftUI

struct NBAAnswerMarkdownView: View {
    let answer: NBAReviewAnswer
    var body: some View {
        VStack(alignment:.leading,spacing:9) {
            ForEach(NBAAnswerMarkdown.blocks(answer)) { block in
                switch block.kind {
                case .bullet: listRow("•",block)
                case .ordered(let marker): listRow(marker,block)
                case .heading: Text(block.text).font(.system(size:14,weight:.medium)).textSelection(.enabled).padding(.top,2)
                case .code: Text(block.text).font(.system(size:12,design:.monospaced)).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                case .quote: Text(block.text).foregroundStyle(.secondary).padding(.leading,10).overlay(alignment:.leading) { Rectangle().fill(Color.secondary.opacity(0.25)).frame(width:2) }.textSelection(.enabled)
                case .paragraph: Text(block.text).lineSpacing(5).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                }
            }
        }.font(.system(size:13)).tint(.blue).frame(maxWidth:.infinity,alignment:.leading)
    }
    private func listRow(_ marker: String,_ block: NBAAnswerMarkdown.Block) -> some View {
        HStack(alignment:.firstTextBaseline,spacing:7) {
            Text(marker).foregroundStyle(.secondary).frame(minWidth:13,alignment:.leading)
            Text(block.text).lineSpacing(4).textSelection(.enabled).fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading)
        }.padding(.leading,CGFloat(block.indent)*12)
    }
}
