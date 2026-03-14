//
//  SendLocationSubpage.swift
//  Mercury Watch App
//
//  Created on 14/03/26.
//

import SwiftUI
import MapKit

struct SendLocationSubpage: View {

    @State var vm: SendLocationViewModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack {
            if let coordinate = vm.coordinate {
                Map(position: .constant(.camera(
                    MapCamera(centerCoordinate: coordinate, distance: 500)
                )), interactionModes: []) {
                    Marker("You", systemImage: "location.fill", coordinate: coordinate)
                        .tint(.blue)
                }
                .mapStyle(.hybrid(pointsOfInterest: .excludingAll))
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Button {
                    vm.sendLocation()
                    isPresented = false
                } label: {
                    Label("Send Location", systemImage: "location.fill")
                }
                .tint(.blue)

            } else if vm.locationError != nil {
                ContentUnavailableView(
                    "Location Unavailable",
                    systemImage: "location.slash",
                    description: Text("Enable Location Services in Settings.")
                )
            } else {
                ProgressView("Getting location...")
            }
        }
        .navigationTitle("Location")
        .onAppear { vm.requestLocation() }
    }
}
