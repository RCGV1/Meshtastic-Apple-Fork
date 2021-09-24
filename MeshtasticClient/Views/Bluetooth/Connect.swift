//
//  DeviceBLE.swift
//  MeshtasticClient
//
//  Created by Garth Vander Houwen on 8/18/21.
//

// Abstract:
//  A view allowing you to interact with nearby meshtastic nodes

import SwiftUI
import MapKit
import CoreLocation

struct Connect: View {
    
    @EnvironmentObject var meshData: MeshData
    
    @EnvironmentObject var bleManager: BLEManager
        
    var body: some View {
        NavigationView {
            
            VStack {
                if bleManager.isSwitchedOn {
                    
                    List {
                        Section(header: Text("Connected Device").font(.title)) {
                            if(bleManager.connectedPeripheral != nil){
                                HStack {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .symbolRenderingMode(.hierarchical)
                                        .imageScale(.large).foregroundColor(.green)
                                        .padding(.trailing)
                                    
                                    if bleManager.connectedNodeInfo.myInfo != nil {
                                        VStack  (alignment: .leading)  {
                                            if bleManager.connectedNode != nil {
                                                
                                                Text(bleManager.connectedNode.user.longName).font(.title2)
                                            }
                                            else {
                                                Text(String(bleManager.connectedNodeInfo.myInfo?.myNodeNum ?? 0)).font(.title2)
                                                
                                            }
                                            Text("FW Version: ").font(.caption)+Text(bleManager.connectedNodeInfo.myInfo?.firmwareVersion ?? "(null)").font(.caption).foregroundColor(Color.gray)
                                        }
                                    }
                                    else {
                                        Text((bleManager.connectedPeripheral.name != nil) ? bleManager.connectedPeripheral.name! : "Unknown").font(.title2)
                                    }
                                }
                                .padding()
                                .swipeActions {
                                    Button {
                                        bleManager.disconnectDevice()
                                    } label: {
                                        VStack {
                                            Label("Disconnect", systemImage: "antenna.radiowaves.left.and.right.slash")
                                        }
                                    }
                                    .tint(.red)
                                }
                            }
                            else {
                                HStack{
                                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                                        .symbolRenderingMode(.hierarchical)
                                        .imageScale(.large).foregroundColor(.red)
                                        .padding(.trailing)
                                    Text("No device connected").font(.title3)
                                }
                                .padding()
                            }
                            
                        }.textCase(nil)
                        
                        Section(header: Text("Available Devices").font(.title)) {
                            ForEach(bleManager.peripherals.sorted(by: { $0.rssi > $1.rssi })) { peripheral in
                                HStack {
                                    Image(systemName: "circle.fill")
                                        .imageScale(.large).foregroundColor(.gray)
                                        .padding(.trailing)
                                    Button(action: {
                                        self.bleManager.stopScanning()
                                        self.bleManager.disconnectDevice()
                                        self.bleManager.connectToDevice(id: peripheral.id)
                                    }) {
                                        Text(peripheral.name).font(.title3)
                                    }
                                    Spacer()
                                    Text(String(peripheral.rssi) + " dB").font(.title3)
                                }.padding([.bottom,.top])
                            }
                        }.textCase(nil)
                        
                    }
                    
                    HStack (alignment: .center) {
                        Spacer()
                        Button(action: {
                            self.bleManager.startScanning()
                        }) {
                            Image(systemName: "play.fill").imageScale(.large).foregroundColor(.gray)
                            Text("Start Scanning").font(.caption)
                            .font(.caption)
                                .foregroundColor(.gray)
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .clipShape(Capsule())
                        Spacer()
                        Button(action: {
                            self.bleManager.stopScanning()
                        }) {
                            Image(systemName: "stop.fill").imageScale(.large).foregroundColor(.gray)
                            Text("Stop Scanning")
                            .font(.caption)
                            .foregroundColor(.gray)
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .clipShape(Capsule())
                        Spacer()
                    }.padding(.bottom, 25)
                    
                }
                else {
                    Text("Bluetooth: OFF")
                        .foregroundColor(.red)
                        .font(.title)
                }
            }
            .navigationTitle("Bluetooth Radios")
            .navigationBarItems(trailing:
                                  
                ZStack {

                    ConnectedDevice(bluetoothOn: bleManager.isSwitchedOn, deviceConnected: bleManager.connectedPeripheral != nil, name: (bleManager.connectedPeripheral != nil) ? bleManager.connectedPeripheral.name : "Unknown")
           
                }
            )
        }.navigationViewStyle(StackNavigationViewStyle())
    }
}

struct Connect_Previews: PreviewProvider {
   // static let meshData = MeshData()
  //  static let bleManager = BLEManager()

    static var previews: some View {
        Connect()
            .environmentObject(MeshData())
            .environmentObject(BLEManager())
            
    }
}