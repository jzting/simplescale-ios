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
    
    // Timer State
    enum TimerState { case idle, running, stopped }
    @Published var timerState: TimerState = .idle
    @Published var timerString: String = "0:00"
    
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
        haptic(style: .medium)
        // Scan for all devices, we will filter by name "TIMEMORE"
        centralManager.scanForPeripherals(withServices: nil, options: nil)
    }
    
    func tare() {
        haptic(style: .heavy)
        guard let peripheral = peripheral, let ctrlChar = ctrlChar else { return }
        let data = Data(tareCommand)
        peripheral.writeValue(data, for: ctrlChar, type: .withoutResponse)
    }
    
    func handleTimer() {
        haptic(style: .medium)
        
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
            timerString = "0:00"
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
        timerString = String(format: "%d:%02d", minutes, seconds)
    }
    
    // MARK: - CoreBluetooth Delegate Methods
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
            if central.state == .poweredOn {
                // Automatically attempt to connect as soon as Bluetooth is ready
                connect()
            } else {
                // Optional: Handle other states (e.g., .poweredOff, .unauthorized)
                // by updating the UI so the user knows why it isn't connecting.
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
        ZStack {
            bgDark.ignoresSafeArea()
            
            VStack {
                Spacer()
                
                // Weight Display
                VStack(spacing: 8) {
                    Text("WEIGHT")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .kerning(2.0)
                        .foregroundColor(.gray)
                    
                    HStack(alignment: .bottom, spacing: 6) {
                        Text(String(format: "%.1f", manager.weight))
                            .font(.system(size: 90, weight: .light, design: .monospaced))
                            .foregroundColor(manager.weight < 0 ? .gray : .white)
                            // Tabular nums to prevent shifting
                            .monospacedDigit()
                        
                        Text("g")
                            .font(.system(size: 30, weight: .light, design: .monospaced))
                            .foregroundColor(unitGray)
                            .padding(.bottom, 15)
                    }
                }
                
                Spacer()
                
                // Timer Display
                VStack(spacing: 8) {
                    Text("TIMER")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .kerning(2.0)
                        .foregroundColor(.gray)
                    
                    Text(manager.timerString)
                        .font(.system(size: 90, weight: .light, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(timerColor)
                }
                
                Spacer()
                
                // Bottom Bar Controls
                HStack(spacing: 14) {
                    if !manager.isConnected {
                        Button(action: { manager.connect() }) {
                            Text(manager.isConnecting ? "CONNECTING..." : "CONNECT")
                        }
                        .disabled(manager.isConnecting)
                        .buttonStyle(ScaleButtonStyle(
                            bg: Color(white: 0.1),
                            fg: manager.isConnecting ? Color(white: 0.3) : Color(white: 0.5),
                            borderColor: Color(white: 0.15)
                        ))
                    } else {
                        Button(action: { manager.handleTimer() }) {
                            Text(timerButtonText)
                        }
                        .buttonStyle(ScaleButtonStyle(
                            bg: timerButtonBg,
                            fg: timerButtonFg,
                            borderColor: timerButtonBorder
                        ))
                        
                        Button(action: { manager.tare() }) {
                            Text("TARE")
                        }
                        .buttonStyle(ScaleButtonStyle(
                            bg: Color(white: 0.1),
                            fg: Color(white: 0.5),
                            borderColor: Color(white: 0.15)
                        ))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
        }
        .preferredColorScheme(.dark)
    }
    
    // Dynamic styling helpers based on state
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
