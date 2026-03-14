//
//  SendLocationViewModel.swift
//  Mercury Watch App
//
//  Created on 14/03/26.
//

import Foundation
import CoreLocation

@Observable
class SendLocationViewModel: NSObject, CLLocationManagerDelegate {

    var coordinate: CLLocationCoordinate2D?
    var locationError: Error?

    private let locationManager = CLLocationManager()
    private let sendService: SendMessageService
    private let logger = LoggerService(SendLocationViewModel.self)

    init(sendService: SendMessageService) {
        self.sendService = sendService
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func requestLocation() {
        let status = locationManager.authorizationStatus
        if status == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else if status == .authorizedWhenInUse || status == .authorizedAlways {
            locationManager.requestLocation()
        } else {
            locationError = CLError(.denied)
        }
    }

    func sendLocation() {
        guard let coordinate else { return }
        sendService.sendLocation(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        coordinate = location.coordinate
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        logger.log(error, level: .error)
        locationError = error
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.requestLocation()
        } else if status == .denied || status == .restricted {
            locationError = CLError(.denied)
        }
    }
}
