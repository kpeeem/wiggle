import SwiftUI

struct SettingsPanel: View {
    @Bindable var project: Project

    var body: some View {
        Form {
            Section("Кадры") {
                LabeledContent("Достроить между снимками") {
                    Stepper(value: $project.options.intermediateFrames, in: 0...15) {
                        Text("\(project.options.intermediateFrames)")
                            .monospacedDigit()
                    }
                }
                Picker("Ширина", selection: $project.options.workingWidth) {
                    Text("1280").tag(1280)
                    Text("1920").tag(1920)
                    Text("2560").tag(2560)
                    Text("3840").tag(3840)
                    Text("Исходная").tag(0)
                }
            }

            Section {
                LabeledContent("Точка") {
                    if let marker = project.convergenceMarker {
                        Text("\(Int(marker.x * 100)) %, \(Int(marker.y * 100)) %")
                            .monospacedDigit()
                    } else {
                        Text("Середина сцены")
                    }
                }
                Button("Сбросить точку") {
                    project.options.convergenceX = nil
                    project.options.convergenceY = nil
                }
                .disabled(project.options.convergenceX == nil)
            } header: {
                Text("Сведение")
            } footer: {
                Text("Нажмите на объект в кадре, и он останется на месте. Остальное будет качаться вокруг него.")
            }

            #if os(macOS)
            Section("Цвет") {
                Picker("Плёнка", selection: $project.options.grade.look) {
                    ForEach(filmLooks, id: \.id) { look in
                        Text(look.title).tag(look.id)
                    }
                }
                GradeSlider(title: "Экспозиция", value: $project.options.grade.exposure, range: -2...2, neutral: 0)
                GradeSlider(title: "Контраст", value: $project.options.grade.contrast, range: 0.5...1.5, neutral: 1)
                GradeSlider(title: "Насыщенность", value: $project.options.grade.saturation, range: 0...2, neutral: 1)
                GradeSlider(title: "Теплота", value: $project.options.grade.warmth, range: -1...1, neutral: 0)
                GradeSlider(title: "Виньетка", value: $project.options.grade.vignette, range: 0...1, neutral: 0)
                Button("Сбросить цвет") {
                    project.options.grade = Grade()
                }
                .disabled(project.options.grade == Grade())
            }

            #endif

            Section("Выравнивание") {
                Toggle("Поворот и вертикаль", isOn: $project.options.alignGeometry)
                Toggle("Яркость и контраст", isOn: $project.options.matchExposure)
                Toggle("Обратный порядок снимков", isOn: $project.options.reversed)
            }

            Section("Движение") {
                Picker("Траектория", selection: $project.options.loop) {
                    Text("Маятник").tag(LoopMode.pingPong)
                    Text("По кругу").tag(LoopMode.forward)
                }
                Picker("Скорость", selection: $project.options.easing) {
                    Text("Замедление у краёв").tag(Easing.smooth)
                    Text("Постоянная").tag(Easing.linear)
                }
                .disabled(project.options.loop == .forward)
                LabeledContent("Качаний за ролик") {
                    Stepper(value: $project.options.swings, in: 1...12) {
                        Text("\(project.options.swings)")
                            .monospacedDigit()
                    }
                }
            }

            Section {
                LabeledContent("Длительность") {
                    Stepper(value: $project.options.duration, in: 1...12, step: 0.5) {
                        Text("\(project.options.duration.formatted(.number.precision(.fractionLength(0...1)))) с")
                            .monospacedDigit()
                    }
                }
                Picker("Кадров в секунду", selection: $project.options.frameRate) {
                    Text("24").tag(24)
                    Text("30").tag(30)
                    Text("60").tag(60)
                }
                Picker("Формат", selection: $project.options.format) {
                    Text("MP4, HEVC").tag(ExportFormat.hevc)
                    Text("MP4, H.264").tag(ExportFormat.h264)
                    Text("GIF").tag(ExportFormat.gif)
                    Text("Live Photo").tag(ExportFormat.livePhoto)
                }
            } header: {
                Text("Экспорт")
            } footer: {
                Text(exportNote)
            }

            Section {
                Button("Вернуть настройки по умолчанию") {
                    var defaults = WiggleOptions()
                    defaults.reversed = project.options.reversed
                    defaults.convergenceX = project.options.convergenceX
                    defaults.convergenceY = project.options.convergenceY
                    project.options = defaults
                }
            }
        }
        .formStyle(.grouped)
    }

    private var exportNote: String {
        let cycle = project.options.cycle.formatted(.number.precision(.fractionLength(0...2)))
        if project.options.format == .gif {
            return String(localized: "В GIF попадает одно качание длиной \(cycle) с, ширина до 720 px. Он повторяется сам.")
        }
        if project.options.format == .livePhoto {
            return String(localized: "Сохраняются два файла с одним именем, HEIC и MOV. Вместе они составляют Live Photo.")
        }
        return String(localized: "Одно качание длится \(cycle) с. Ролик заканчивается там же, где начался, и зацикливается без шва.")
    }
}

struct GradeSlider: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let neutral: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text((value - neutral).formatted(.number.precision(.fractionLength(2)).sign(strategy: .always(includingZero: false))))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
                .accessibilityLabel(title)
        }
    }
}
