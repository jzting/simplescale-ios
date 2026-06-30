//
//  ContentView.swift
//  simplescale
//
//  Created by Jason Ting on 6/26/26.
//

import SwiftUI
import CoreBluetooth
import Combine

// MARK: - View Model (CoreBluetooth & Timer Logic)
class ScaleManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    
    // BLE State
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var weight: Double = 0.0
    
    // Add this to handle the Tare flash
    private var ignoreWeightUpdatesUntil: Date?
    
    // Timer State
    enum TimerState { case idle, running, stopped }
    @Published var timerState: TimerState = .idle
    @Published var timerString: String = "00:00"
    
    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var ctrlChar: CBCharacteristic?
    
    // Timer variables
    private var timer: Timer?
    private var timerStartTime: Date?
    private var timerElapsed: TimeInterval = 0
    
    // BLE Constants
    private let serviceUUID = CBUUID(string: "FFF0")
    private let dataCharUUID = CBUUID(string: "FFF1")
    private let ctrlCharUUID = CBUUID(string: "FFF2")
    private let tareCommand: [UInt8] = [0xA5, 0x5A, 0x03, 0x0D, 0x00, 0x02, 0x00, 0x00, 0x00, 0x71]
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    // MARK: - Intentions
    func connect() {
        guard centralManager.state == .poweredOn else { return }
        isConnecting = true
        haptic(style: .heavy)
        // Scan for all devices, we will filter by name "TIMEMORE"
        centralManager.scanForPeripherals(withServices: nil, options: nil)
    }
    
    func tare() {
        haptic(style: .heavy)
        guard let peripheral = peripheral, let ctrlChar = ctrlChar else { return }
        
        // Optimistically set to 0.0 and ignore incoming BLE packets for 500ms
        DispatchQueue.main.async {
            self.weight = 0.0
        }
        self.ignoreWeightUpdatesUntil = Date().addingTimeInterval(0.5)
        
        let data = Data(tareCommand)
        peripheral.writeValue(data, for: ctrlChar, type: .withoutResponse)
    }
    
    func handleTimer() {
        haptic(style: .heavy)
        
        switch timerState {
        case .idle:
            timerStartTime = Date()
            timerState = .running
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.updateTimerUI()
            }
        case .running:
            timer?.invalidate()
            timer = nil
            if let start = timerStartTime {
                timerElapsed += Date().timeIntervalSince(start)
            }
            timerState = .stopped
            updateTimerUI()
        case .stopped:
            haptic(style: .heavy)
            timerElapsed = 0
            timerState = .idle
            timerString = "00:00"
        }
    }
    
    private func updateTimerUI() {
        var totalElapsed = timerElapsed
        if timerState == .running, let start = timerStartTime {
            totalElapsed += Date().timeIntervalSince(start)
        }
        
        let totalSeconds = Int(totalElapsed)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        timerString = String(format: "%02d:%02d", minutes, seconds)
    }
    
    // MARK: - CoreBluetooth Delegate Methods
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            connect()
        } else {
            DispatchQueue.main.async {
                self.isConnected = false
                self.isConnecting = false
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if let name = peripheral.name, name.hasPrefix("TIMEMORE") {
            centralManager.stopScan()
            self.peripheral = peripheral
            self.peripheral?.delegate = self
            centralManager.connect(peripheral, options: nil)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([serviceUUID])
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        DispatchQueue.main.async {
            self.isConnected = false
            self.isConnecting = false
            self.weight = 0.0
            
            self.timer?.invalidate()
            self.timer = nil
            self.timerElapsed = 0
            self.timerState = .idle
            self.timerString = "00:00"
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == serviceUUID {
            peripheral.discoverCharacteristics([dataCharUUID, ctrlCharUUID], for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        
        for char in characteristics {
            if char.uuid == dataCharUUID {
                peripheral.setNotifyValue(true, for: char)
            } else if char.uuid == ctrlCharUUID {
                self.ctrlChar = char
            }
        }
        
        DispatchQueue.main.async {
            self.isConnected = true
            self.isConnecting = false
            self.haptic(style: .heavy)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == dataCharUUID, let data = characteristic.value else { return }
        
        let bytes = [UInt8](data)
        if bytes.count >= 10 && bytes[0] == 0xA5 && bytes[1] == 0x5A {
            let raw = (Int(bytes[8]) << 8) | Int(bytes[9])
            let parsedWeight = raw > 30000 ? Double(raw - 65536) * 0.1 : Double(raw) * 0.1
            
            DispatchQueue.main.async {
                // If we recently tared, ignore in-flight packets
                if let ignoreUntil = self.ignoreWeightUpdatesUntil, Date() < ignoreUntil {
                    return
                }
                
                self.weight = parsedWeight
            }
        }
    }
    
    // MARK: - Haptics
    private func haptic(style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
    }
}

// MARK: - SwiftUI Views
struct ContentView: View {
    @StateObject private var manager = ScaleManager()
    
    // Colors matching CSS
    let bgDark = Color(red: 13/255, green: 13/255, blue: 13/255)
    let textGray = Color(red: 0.2, green: 0.2, blue: 0.2)
    let unitGray = Color(red: 0.16, green: 0.16, blue: 0.16)
    
    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            
            ZStack {
                bgDark.ignoresSafeArea()
                
                if isLandscape {
                    // MARK: - Landscape Layout
                    VStack {
                        // 1. Displays (Two-Column Layout)
                        HStack(spacing: 14) {
                            // Timer Column
                            VStack {
                                Spacer()
                                timerDisplay
                                Spacer()
                            }
                            .frame(maxWidth: .infinity)
                            
                            // Weight Column
                            VStack {
                                Spacer()
                                weightDisplay
                                Spacer()
                            }
                            .frame(maxWidth: .infinity)
                        }
                        
                        // 2. Controls (Centered or Split)
                        if !manager.isConnected {
                            connectButton
                            // Constrain the max width so it doesn't stretch across the entire landscape screen
                                .frame(maxWidth: 400)
                        } else {
                            // Matches the top HStack spacing so the buttons align perfectly under their columns
                            HStack(spacing: 14) {
                                timerButton
                                    .padding(.horizontal, 50)
                                
                                tareButton
                                    .padding(.horizontal, 50)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
                    
                } else {
                    // MARK: - Portrait (Vertical Layout)
                    VStack {
                        Spacer()
                        timerDisplay
                        
                        Spacer()
                        
                        // Thin dark gray separator line
                        Rectangle()
                            .fill(Color(white: 0.1))
                            .frame(height: 1)
                            .padding(.horizontal, 50)
                        
                        Spacer()
                        
                        weightDisplay
                        Spacer()
                        
                        // Bottom Bar Controls
                        HStack(spacing: 14) {
                            if !manager.isConnected {
                                connectButton
                            } else {
                                timerButton
                                tareButton
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden) // <--- Hides the swipe-to-home indicator
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }
    // MARK: - Display Subviews
    private var weightDisplay: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 6) {
                
                // 1. Invisible placeholder to balance the HStack and center the weight
                Text("g")
                    .font(.system(size: 30, weight: .light, design: .monospaced))
                    .padding(.bottom, 15)
                    .hidden()
                
                // 2. The centered numerical weight (Using our new dynamic formatter)
                Text(formattedWeightString)
                    .font(.system(size: 90, weight: .light, design: .monospaced))
                    .foregroundColor(weightColor)
                    .monospacedDigit()
                
                // 3. The actual visible unit
                Text("g")
                    .font(.system(size: 30, weight: .light, design: .monospaced))
                    .foregroundColor(manager.isConnected ? unitGray : Color(white: 0.18))
                    .padding(.bottom, 15)
            }
        }
    }
    
    private var timerDisplay: some View {
        VStack(spacing: 8) {
            Text(manager.timerString)
                .font(.system(size: 90, weight: .light, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(timerColor)
        }
    }
    
    // MARK: - Button Subviews
    private var connectButton: some View {
        Button(action: { manager.connect() }) {
            Text(manager.isConnecting ? "CONNECTING..." : "CONNECT")
        }
        .disabled(manager.isConnecting)
        .buttonStyle(ScaleButtonStyle(
            bg: Color(white: 0.1),
            fg: manager.isConnecting ? Color(white: 0.3) : Color(white: 0.5),
            borderColor: Color(white: 0.15)
        ))
    }
    
    private var timerButton: some View {
        Button(action: { manager.handleTimer() }) {
            Text(timerButtonText)
        }
        .buttonStyle(ScaleButtonStyle(
            bg: timerButtonBg,
            fg: timerButtonFg,
            borderColor: timerButtonBorder
        ))
    }
    
    private var tareButton: some View {
        Button(action: { manager.tare() }) {
            Text("TARE")
        }
        .buttonStyle(ScaleButtonStyle(
            bg: Color(white: 0.1),
            fg: Color(white: 0.5),
            borderColor: Color(white: 0.15)
        ))
    }
    
    // MARK: - Dynamic Styling Helpers
    private var weightColor: Color {
        // Return the idle timer color (0.18 white) if disconnected OR if weight is exactly 0
        if !manager.isConnected || manager.weight == 0 {
            return Color(white: 0.18)
        }
        
        // Return the "stop button" red color if weight is negative, otherwise white
        return manager.weight < 0 ? Color(red: 1.0, green: 0.33, blue: 0.33) : .white
    }
    
    private var timerColor: Color {
        switch manager.timerState {
        case .idle: return Color(white: 0.18)
        case .running: return .white
        case .stopped: return Color(white: 0.53)
        }
    }
    
    private var timerButtonText: String {
        switch manager.timerState {
        case .idle: return "START"
        case .running: return "STOP"
        case .stopped: return "RESET"
        }
    }
    
    private var timerButtonBg: Color {
        switch manager.timerState {
        case .idle: return Color(white: 0.1)
        case .running: return Color(red: 0.1, green: 0.04, blue: 0.04)
        case .stopped: return .clear
        }
    }
    
    private var timerButtonFg: Color {
        switch manager.timerState {
        case .idle: return Color(white: 0.5)
        case .running: return Color(red: 1.0, green: 0.33, blue: 0.33)
        case .stopped: return Color(white: 0.33)
        }
    }
    
    private var timerButtonBorder: Color {
        switch manager.timerState {
        case .idle: return Color(white: 0.15)
        case .running: return Color(red: 0.22, green: 0.06, blue: 0.06)
        case .stopped: return Color(white: 0.16)
        }
    }
    
    private var formattedWeightString: String {
        let absoluteWeight = abs(manager.weight)        
        return String(format: "%.1f", absoluteWeight)
    }
}

// MARK: - Custom Button Style
struct ScaleButtonStyle: ButtonStyle {
    var bg: Color
    var fg: Color
    var borderColor: Color
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .textCase(.uppercase)
            .kerning(1.2)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(bg)
            .foregroundColor(fg)
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(borderColor, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.75 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

#Preview {
    ContentView()
}
