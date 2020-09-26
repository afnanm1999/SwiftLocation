//
//  Locator.swift
//  SwiftLocation
//
//  Created by Daniele Margutti on 17/09/2020.
//

import Foundation
import CoreLocation

public class Locator: LocationManagerDelegate {
        
    // MARK: - Private Properties

    private var manager: LocationManagerProtocol?
    
    // MARK: - Public Properties
    
    /// Shared instance.
    public static let shared = Locator()
    
    /// Currently active location settings
    public private(set) var currentSettings = LocationManagerSettings() {
        didSet {
            guard currentSettings != oldValue else {
                LocatorLogger.log("CLLocationManager: **settings ignored**")
                return
            } // same settings, no needs to perform any change

            LocatorLogger.log("CLLocationManager: \(currentSettings)")
            manager?.updateSettings(currentSettings)
        }
    }
    
    /// Queued location result.
    public lazy var locationQueue: RequestQueue<LocationRequest> = {
        let queue = RequestQueue<LocationRequest>()
        queue.onUpdateSettings = { [weak self] in
            self?.updateCoreLocationManagerSettings()
        }
        return queue
    }()
    
    public lazy var ipLocationQueue: RequestQueue<IPLocationRequest> = {
        let queue = RequestQueue<IPLocationRequest>()
        queue.onUpdateSettings = { [weak self] in
            self?.updateCoreLocationManagerSettings()
        }
        return queue
    }()
        
    /// Authorization mode. By default the best authorization to get is based upon the plist file.
    /// If plist contains always usage description the always mode is used, otherwise only whenInUse is preferred.
    public var preferredAuthorizationMode: AuthorizationMode = .plist
    
    /// Current authorization status.
    public var authorizationStatus: CLAuthorizationStatus {
        return manager?.authorizationStatus ?? .notDetermined
    }
    
    // MARK: - Initialization
    
    private init() {
        do {
            try setUnderlyingManager(DeviceLocationManager(locator: self))
        } catch {
            fatalError("Failed to setup Locator: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Public Properties
    
    /// This functiction change the underlying manager which manage the hardware. By default the `CLLocationManager` based
    /// object is used (`DeviceLocationManager`); this function should not be called directly but it's used for unit test.
    /// - Parameter manager: manager to use.
    /// - Throws: throw an exception if something fail.
    public func setUnderlyingManager(_ manager: LocationManagerProtocol) throws {
        resetAll() // reset all queues
        
        self.manager = try DeviceLocationManager(locator: self)
        self.manager?.delegate = self
    }
    
    /// Get the location with given options.
    ///
    /// - Parameter optionsBuilder: options for search.
    /// - Returns: `LocationRequest`
    @discardableResult
    public func getLocation(_ optionsBuilder: ((LocationOptions) -> Void)) -> LocationRequest {
        let newRequest = LocationRequest()
        optionsBuilder(newRequest.options)
        return locationQueue.add(newRequest)
    }
    
    /// Get the location with given passed options data.
    /// - Parameter options: options to use.
    /// - Returns: `LocationRequest`
    public func getLocation(_ options: LocationOptions) -> LocationRequest {
        locationQueue.add(LocationRequest(options))
    }
    
    /// Get the current approximate location by asking to the passed service.
    /// - Parameter service: service to use.
    /// - Returns: `IPLocationRequest`
    public func getLocationByIP(_ service: IPService) -> IPLocationRequest {
        ipLocationQueue.add(IPLocationRequest(service))
    }
    
    /// Cancel passed request from queue.
    ///
    /// - Parameter request: request.
    public func cancel(request: Any) {
        switch request {
        case let location as LocationRequest:
            locationQueue.remove(location)
            
        default:
            break
        }
    }
    
    /// Cancel subscription token with given id from their associated request.
    /// - Parameter tokenID: token identifier.
    public func cancel(subscription identifier: Identifier) {
        locationQueue.list.first(where: { $0.subscriptionWithID(identifier) != nil })?.cancel(subscription: identifier)
    }
    
    // MARK: - Private Functions
    
    /// Reset all location requests and manager's settings.
    private func resetAll() {
        locationQueue.removeAll()
        updateCoreLocationManagerSettings()
    }
    
    /// Update the settings of underlying core manager based upon the current settings.
    private func updateCoreLocationManagerSettings() {
        defer {
            startRequestsTimeoutsIfSet()
        }
        
        let updatedSettings = bestSettingsForCoreLocationManager()
        guard updatedSettings.requireLocationUpdates() else {
            self.currentSettings = updatedSettings
            return
        }
        
        failWeakAuthorizationRequests()
        
        manager?.requestAuthorization(preferredAuthorizationMode) { [weak self] auth in
            guard auth.isAuthorized else {
                return
            }
            self?.currentSettings = updatedSettings
            return
        }
    }
    
    private func failWeakAuthorizationRequests() {
        guard authorizationStatus.isAuthorized == false else {
            // If we have already the authorization even request with `avoidRequestAuthorization = true`
            // may receive notifications of locations.
            return
        }
        
        // If we have not authorization all requests with `avoidRequestAuthorization = true` should
        // fails with `authorizationNeeded` error.
        dispatchLocationDataToRequests(filter: {
            $0.options.avoidRequestAuthorization
        }, .failure(.authorizationNeeded))
    }
    
    private func startRequestsTimeoutsIfSet() {
        enumerateLocationRequests { request in
            request.startTimeoutIfNeeded()
        }
    }
    
    private func bestSettingsForCoreLocationManager() -> LocationManagerSettings {
        var services = Set<LocationManagerSettings.Services>()
        var settings = LocationManagerSettings(activeServices: services)
        
        print("\(locationQueue.list.count) requests")
        enumerateLocationRequests { request in
            services.insert(request.options.subscription.service)
            
            settings.accuracy = min(settings.accuracy, request.options.accuracy)
            settings.minDistance = min(settings.minDistance ?? -1, request.options.minDistance ?? -1)
            settings.activityType = CLActivityType(rawValue: max(settings.activityType.rawValue, request.options.activityType.rawValue)) ?? .other
        }
        
        if settings.minDistance == -1 { settings.minDistance = nil }
        settings.activeServices = services
        
        return settings
    }
    
    // MARK: - LocationManagerDelegate
    
    public func locationManager(didFailWithError error: Error) {
        dispatchLocationDataToRequests(.failure(.generic(error)))
    }
    
    public func locationManager(didReceiveLocations locations: [CLLocation]) {
        dispatchLocationUpdate(locations)
    }
    
    // MARK: - Private Functions
    
    private func dispatchLocationUpdate(_ locations: [CLLocation]) {
        guard let lastLocation = locations.max(by: CLLocation.mostRecentsTimeStampCompare) else {
            return
        }
        
        dispatchLocationDataToRequests(.success(lastLocation))
    }
    
    private func enumerateLocationRequests(_ callback: ((LocationRequest) -> Void)) {
        let requests = locationQueue
        requests.list.forEach(callback)
    }
    
    private func dispatchLocationDataToRequests(filter: ((LocationRequest) -> Bool)? = nil, _ data: Result<CLLocation, LocatorErrors>) {
        enumerateLocationRequests { request in
            if filter?(request) ?? true {
                if let discardReason = request.receiveData(data) {
                    LocatorLogger.log("𝗑 Location discarded from \(request.uuid): \(discardReason.description)")
                }
            }
        }
    }
    
}

public extension Locator {
    
    class RequestQueue<Value: RequestProtocol> {
        /// List of enqueued requests.
        public private(set) var list = Set<Value>()
        
        @discardableResult
        internal func add(_ request: Value) -> Value {
            LocatorLogger.log("+ Add new request: \(request.uuid)")
            
            list.insert(request)
            request.didAddInQueue()
            
            onUpdateSettings?()
            return request
        }

        @discardableResult
        internal func remove(_ request: Value) -> Value {
            LocatorLogger.log("- Remove request: \(request.uuid)")
            
            list.remove(request)
            request.didRemovedFromQueue()
            
            onUpdateSettings?()
            return request
        }
        
        internal func removeAll() {
            guard !list.isEmpty else { return }
            
            let removedRequests = list
            LocatorLogger.log("- Remove all \(list.count) requests")
            list.removeAll()
            
            removedRequests.forEach({ $0.didRemovedFromQueue() })
            
            onUpdateSettings?()
        }
        
        internal var onUpdateSettings: (() -> Void)?
    }
    
}
