//
//  AboutSettings.swift
//  MenuScores
//
//  Created by Daniyal Master on 2026-08-01.
//

import AppKit
import SwiftUI

struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 4) {
            Form {
                Section("版本信息") {
                    HStack {
                        Text("版本")
                        Spacer()

                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("构建号")
                        Spacer()

                        Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "未知")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("项目与来源") {
                    Text("独立维护版 · 菜单栏比分与数据追踪")
                        .font(.caption).foregroundStyle(.secondary)
                    let links = [
                        ("本项目源代码", "https://github.com/ylx-vt/MenuScores"),
                        ("原项目 · Daniyal Master", "https://github.com/daniyalmaster693/MenuScores")
                    ]

                    ForEach(links, id: \.0) { link in
                        Button {
                            if let url = URL(string: link.1) {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            HStack {
                                Text(link.0)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}
