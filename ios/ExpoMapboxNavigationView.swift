import ExpoModulesCore
import MapboxNavigationCore
import MapboxMaps
import MapboxNavigationUIKit
import MapboxDirections
import Combine


class ExpoMapboxNavigationView: ExpoView {
    private let onRouteProgressChanged = EventDispatcher()
    private let onCancelNavigation = EventDispatcher()
    private let onWaypointArrival = EventDispatcher()
    private let onFinalDestinationArrival = EventDispatcher()
    private let onRouteChanged = EventDispatcher()
    private let onUserOffRoute = EventDispatcher()
    private let onRoutesLoaded = EventDispatcher()
    private let onRouteFailedToLoad = EventDispatcher()

    let controller = ExpoMapboxNavigationViewController()

    required init(appContext: AppContext? = nil) {
        super.init(appContext: appContext)
        clipsToBounds = true
        addSubview(controller.view)

        controller.onRouteProgressChanged = onRouteProgressChanged
        controller.onCancelNavigation = onCancelNavigation
        controller.onWaypointArrival = onWaypointArrival
        controller.onFinalDestinationArrival = onFinalDestinationArrival
        controller.onRouteChanged = onRouteChanged
        controller.onUserOffRoute = onUserOffRoute
        controller.onRoutesLoaded = onRoutesLoaded
        controller.onRouteFailedToLoad = onRouteFailedToLoad
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        controller.view.frame = bounds
    }
}


class ExpoMapboxNavigationViewController: UIViewController {
    static let navigationProvider: MapboxNavigationProvider = MapboxNavigationProvider(coreConfig: CoreConfig(routingConfig: RoutingConfig(fasterRouteDetectionConfig: Optional<FasterRouteDetectionConfig>.none),locationSource: .live ))
    var mapboxNavigation: MapboxNavigation?
    var routingProvider: RoutingProvider?
    var navigation: NavigationController?
    var tripSession: SessionController?
    var navigationViewController: NavigationViewController?
    
    var currentCoordinates: Array<CLLocationCoordinate2D>?
    var initialLocation: CLLocationCoordinate2D?
    var initialLocationZoom: Double?
    var currentWaypointIndices: Array<Int>?
    var currentLocale: Locale = Locale.current
    var currentRouteProfile: String?
    var currentRouteExcludeList: Array<String>?
    var currentMapStyle: String?
    var currentCustomRasterSourceUrl: String?
    var currentPlaceCustomRasterLayerAbove: String?
    var currentDisableAlternativeRoutes: Bool?
    var isUsingRouteMatchingApi: Bool = false
    var vehicleMaxHeight: Double?
    var vehicleMaxWidth: Double?
    var force2D: Bool = false
    var useMetricUnits: Bool = true
    
    // Throttling properties with thread safety
    private let cameraUpdateQueue = DispatchQueue(label: "com.mapbox.cameraUpdate")
    private var lastCameraUpdateTime: TimeInterval = 0
    private let cameraUpdateInterval: TimeInterval = 0.5

    var onRouteProgressChanged: EventDispatcher?
    var onCancelNavigation: EventDispatcher?
    var onWaypointArrival: EventDispatcher?
    var onFinalDestinationArrival: EventDispatcher?
    var onRouteChanged: EventDispatcher?
    var onUserOffRoute: EventDispatcher?
    var onRoutesLoaded: EventDispatcher?
    var onRouteFailedToLoad: EventDispatcher?

    var calculateRoutesTask: Task<Void, Error>?
    private var routeProgressCancellable: AnyCancellable?
    private var waypointArrivalCancellable: AnyCancellable?
    private var reroutingCancellable: AnyCancellable?
    private var sessionCancellable: AnyCancellable?
    private var locationUpdateCancellable: AnyCancellable?

    init() {
        super.init(nibName: nil, bundle: nil)
        setupNavigation()
    }
    
    private func setupNavigation() {
        mapboxNavigation = ExpoMapboxNavigationViewController.navigationProvider.mapboxNavigation
        
        guard let mapboxNavigation = mapboxNavigation else {
            print("ERROR: Failed to initialize mapboxNavigation")
            return
        }
        
        routingProvider = mapboxNavigation.routingProvider()
        navigation = mapboxNavigation.navigation()
        tripSession = mapboxNavigation.tripSession()
        
        guard let navigation = navigation else {
            print("ERROR: Failed to get navigation controller")
            return
        }

        routeProgressCancellable = navigation.routeProgress.sink { [weak self] progressState in
            guard let progressState = progressState else { return }
            self?.onRouteProgressChanged?([
                "distanceRemaining": progressState.routeProgress.distanceRemaining,
                "distanceTraveled": progressState.routeProgress.distanceTraveled,
                "durationRemaining": progressState.routeProgress.durationRemaining,
                "fractionTraveled": progressState.routeProgress.fractionTraveled,
            ])
        }

        waypointArrivalCancellable = navigation.waypointsArrival.sink { [weak self] arrivalStatus in
            let event = arrivalStatus.event
            if event is WaypointArrivalStatus.Events.ToFinalDestination {
                self?.onFinalDestinationArrival?()
            } else if event is WaypointArrivalStatus.Events.ToWaypoint {
                self?.onWaypointArrival?()
            }
        }

        reroutingCancellable = navigation.rerouting.sink { [weak self] _ in
            self?.onRouteChanged?()
        }

        sessionCancellable = tripSession?.session.sink { [weak self] session in 
            let state = session.state
            switch state {
                case .activeGuidance(let activeGuidanceState):
                    switch activeGuidanceState {
                        case .offRoute:
                            self?.onUserOffRoute?()
                        default: 
                            break
                    }
                default: 
                    break
            }
        }

        setupThrottledLocationUpdates()
    }
    
    private func setupThrottledLocationUpdates() {
        guard let navigation = navigation else { return }
        
        locationUpdateCancellable = navigation.locationMatching
            .compactMap { $0.location }
            .throttle(for: .seconds(cameraUpdateInterval),
                    scheduler: DispatchQueue.main,
                    latest: true)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.cameraUpdateQueue.async {
                    self.lastCameraUpdateTime = Date().timeIntervalSince1970
                }
            }
    }

    deinit {
        calculateRoutesTask?.cancel()
        routeProgressCancellable?.cancel()
        waypointArrivalCancellable?.cancel()
        reroutingCancellable?.cancel()
        sessionCancellable?.cancel()
        locationUpdateCancellable?.cancel()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        Task { @MainActor in 
            self.tripSession?.setToIdle() 
        }
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("This controller should not be loaded through a story board")
    }

    func addCustomRasterLayer() {
        guard let navigationMapView = navigationViewController?.navigationMapView,
              let mapView = navigationMapView.mapView.mapboxMap else {
            return
        }
        
        let sourceId = "raster-source"
        let layerId = "raster-layer"

        if currentCustomRasterSourceUrl == nil {
            if mapView.layerExists(withId: layerId) {
                try? mapView.removeLayer(withId: layerId)
            }
            if mapView.sourceExists(withId: sourceId) {
                try? mapView.removeSource(withId: sourceId)
            }
            return
        }

        let sourceUrl = currentCustomRasterSourceUrl!

        var rasterSource = RasterSource(id: sourceId)
        rasterSource.tiles = [sourceUrl]
        rasterSource.tileSize = 256

        let rasterLayer = RasterLayer(id: layerId, source: sourceId)

        if mapView.layerExists(withId: layerId) {
            try? mapView.removeLayer(withId: layerId)
        }
        if mapView.sourceExists(withId: sourceId) {
            try? mapView.removeSource(withId: sourceId)
        }

        try? mapView.addSource(rasterSource)
        try? mapView.addLayer(rasterLayer, layerPosition: .above(currentPlaceCustomRasterLayerAbove ?? "water"))
    }


    func setCoordinates(coordinates: Array<CLLocationCoordinate2D>) {
        currentCoordinates = coordinates
        update()
    }

    func setVehicleMaxHeight(maxHeight: Double?) {
        vehicleMaxHeight = maxHeight
        update()
    }

    func setVehicleMaxWidth(maxWidth: Double?) {
        vehicleMaxWidth = maxWidth
        update()
    }

    func setLocale(locale: String?) {
        if let locale = locale {
            currentLocale = Locale(identifier: locale)
        } else {
            currentLocale = Locale.current
        }
        update()
    }

    func setIsUsingRouteMatchingApi(useRouteMatchingApi: Bool?){
        isUsingRouteMatchingApi = useRouteMatchingApi ?? false
        update()
    }

    func setWaypointIndices(waypointIndices: Array<Int>?){
        currentWaypointIndices = waypointIndices
        update()
    }

    func setRouteProfile(profile: String?){
        currentRouteProfile = profile
        update()
    }

    func setRouteExcludeList(excludeList: Array<String>?){
        currentRouteExcludeList = excludeList
        update()
    }

    func setMapStyle(style: String?){
        currentMapStyle = style
        update()
    }

    func setCustomRasterSourceUrl(url: String?){
        currentCustomRasterSourceUrl = url
        update()
    }

    func setPlaceCustomRasterLayerAbove(layerId: String?){
        currentPlaceCustomRasterLayerAbove = layerId
        update()
    }

    func setDisableAlternativeRoutes(disableAlternativeRoutes: Bool?){
        currentDisableAlternativeRoutes = disableAlternativeRoutes
        update()
    }
    
    func setForce2D(force2D: Bool?) {
        self.force2D = force2D ?? false
        update()
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let pitch: CGFloat = self.force2D ? 0.0 : 40.0
            self.navigationViewController?.navigationMapView?.mapView.mapboxMap.setCamera(to: CameraOptions(pitch: pitch))
        }
    }
    
    func setUseMetricUnits(useMetric: Bool?) {
        self.useMetricUnits = useMetric ?? true
        update()
    }

    func recenterMap(){
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let navigationMapView = self.navigationViewController?.navigationMapView
            navigationMapView?.navigationCamera.update(cameraState: .following)
            
            if self.force2D {
                navigationMapView?.mapView.mapboxMap.setCamera(to: CameraOptions(pitch: 0.0))
            }
        }
    }

    func setIsMuted(isMuted: Bool?){
        if let isMuted = isMuted {
            ExpoMapboxNavigationViewController.navigationProvider.routeVoiceController.speechSynthesizer.muted = isMuted
        }
    }

    func setInitialLocation(location: CLLocationCoordinate2D, zoom: Double?){
        initialLocation = location
        initialLocationZoom = zoom
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let navigationMapView = self.navigationViewController?.navigationMapView else {
                return
            }
            
            let pitch: CGFloat? = self.force2D ? 0.0 : nil
            navigationMapView.mapView.mapboxMap.setCamera(to: CameraOptions(
                center: location,
                zoom: zoom ?? 15,
                pitch: pitch
            ))
        }
    }

    func update(){
        calculateRoutesTask?.cancel()

        guard let coordinates = currentCoordinates else { return }
        
        let waypoints = coordinates.enumerated().map { index, coordinate in
            var waypoint = Waypoint(coordinate: coordinate)
            waypoint.separatesLegs = currentWaypointIndices == nil ? true : currentWaypointIndices!.contains(index)
            return waypoint
        }

        if isUsingRouteMatchingApi {
            calculateMapMatchingRoutes(waypoints: waypoints)
        } else {
            calculateRoutes(waypoints: waypoints)
        }
    }

    func calculateRoutes(waypoints: Array<Waypoint>){
        guard let routingProvider = routingProvider else {
            print("ERROR: Routing provider is nil")
            return
        }
        
        let distanceUnit: LengthFormatter.Unit = useMetricUnits ? .meter : .mile
        
        let routeOptions = NavigationRouteOptions(
            waypoints: waypoints,
            profileIdentifier: currentRouteProfile != nil ? ProfileIdentifier(rawValue: currentRouteProfile!) : nil,
            queryItems: [
                URLQueryItem(name: "exclude", value: currentRouteExcludeList?.joined(separator: ",")),
                URLQueryItem(name: "max_height", value: String(format: "%.1f", vehicleMaxHeight ?? 0.0)),
                URLQueryItem(name: "max_width", value: String(format: "%.1f", vehicleMaxWidth ?? 0.0)),
                URLQueryItem(name: "voice_units", value: useMetricUnits ? "metric" : "imperial")
            ],
            locale: currentLocale,
            distanceUnit: distanceUnit
        )

        calculateRoutesTask = Task { [weak self] in
            guard let self = self else { return }
            
            let result = await routingProvider.calculateRoutes(options: routeOptions).result
            
            await MainActor.run {
                switch result {
                case .failure(let error):
                    self.onRouteFailedToLoad?([
                        "errorMessage": error.localizedDescription
                    ])
                    print("Route calculation error: \(error.localizedDescription)")
                case .success(let navigationRoutes):
                    self.onRoutesCalculated(navigationRoutes: navigationRoutes)
                }
            }
        }
    }

    func calculateMapMatchingRoutes(waypoints: Array<Waypoint>){
        guard let routingProvider = routingProvider else {
            print("ERROR: Routing provider is nil")
            return
        }
        
        let distanceUnit: LengthFormatter.Unit = useMetricUnits ? .meter : .mile
        
        let matchOptions = NavigationMatchOptions(
            waypoints: waypoints,
            profileIdentifier: currentRouteProfile != nil ? ProfileIdentifier(rawValue: currentRouteProfile!) : nil,
            queryItems: [URLQueryItem(name: "exclude", value: currentRouteExcludeList?.joined(separator: ","))],
            distanceUnit: distanceUnit
        )
        matchOptions.locale = currentLocale

        calculateRoutesTask = Task { [weak self] in
            guard let self = self else { return }
            
            let result = await routingProvider.calculateRoutes(options: matchOptions).result
            
            await MainActor.run {
                switch result {
                case .failure(let error):
                    self.onRouteFailedToLoad?([
                        "errorMessage": error.localizedDescription
                    ])
                    print("Route matching error: \(error.localizedDescription)")
                case .success(let navigationRoutes):
                    self.onRoutesCalculated(navigationRoutes: navigationRoutes)
                }
            }
        }
    }

    @objc func cancelButtonClicked(_ sender: AnyObject?) {
        onCancelNavigation?()
    }

    func convertRoute(route: Route) -> Any {
        return [
            "distance": route.distance,
            "expectedTravelTime": route.expectedTravelTime,
            "legs": route.legs.map { leg in
                return [
                    "source": leg.source != nil ? [
                        "latitude": leg.source!.coordinate.latitude,
                        "longitude": leg.source!.coordinate.longitude
                    ] : nil,
                    "destination": leg.destination != nil ? [
                        "latitude": leg.destination!.coordinate.latitude,
                        "longitude": leg.destination!.coordinate.longitude
                    ] : nil,
                    "steps": leg.steps.map { step in
                        return [
                            "shape": step.shape != nil ? [
                                "coordinates": step.shape!.coordinates.map { coordinate in
                                    return [
                                        "latitude": coordinate.latitude,
                                        "longitude": coordinate.longitude,
                                    ]
                                }
                            ] : nil
                        ]
                    }
                ]
            }
        ]
    }

    func onRoutesCalculated(navigationRoutes: NavigationRoutes){
        guard let mapboxNavigation = mapboxNavigation else {
            print("ERROR: mapboxNavigation is nil in onRoutesCalculated")
            return
        }
        
        onRoutesLoaded?([
            "routes": [
                "mainRoute": convertRoute(route: navigationRoutes.mainRoute.route),
                "alternativeRoutes": navigationRoutes.alternativeRoutes.map { convertRoute(route: $0.route) }
            ]
        ])

        let topBanner = TopBannerViewController()
        topBanner.instructionsBannerView.distanceFormatter.locale = currentLocale
        let bottomBanner = BottomBannerViewController()
        bottomBanner.distanceFormatter.locale = currentLocale
        bottomBanner.dateFormatter.locale = currentLocale

        let navigationOptions = NavigationOptions(
            mapboxNavigation: mapboxNavigation,
            voiceController: ExpoMapboxNavigationViewController.navigationProvider.routeVoiceController,
            eventsManager: ExpoMapboxNavigationViewController.navigationProvider.eventsManager(),
            styles: [DayStyle()],
            topBanner: topBanner,
            bottomBanner: bottomBanner
        )

        let newNavigationControllerRequired = navigationViewController == nil

        if newNavigationControllerRequired {
            navigationViewController = NavigationViewController(
                navigationRoutes: navigationRoutes,
                navigationOptions: navigationOptions
            )
        } else {
            navigationViewController?.prepareViewLoading(
                navigationRoutes: navigationRoutes,
                navigationOptions: navigationOptions
            )
        }
        
        guard let navigationViewController = navigationViewController else {
            print("ERROR: Failed to create navigationViewController")
            return
        }

        navigationViewController.showsContinuousAlternatives = currentDisableAlternativeRoutes != true
        navigationViewController.usesNightStyleWhileInTunnel = false
        navigationViewController.automaticallyAdjustsStyleForTimeOfDay = false

        guard let navigationMapView = navigationViewController.navigationMapView else {
            print("ERROR: navigationMapView is nil")
            return
        }
        
        navigationMapView.puckType = .puck2D(.navigationDefault)

        if initialLocation != nil && newNavigationControllerRequired {
            let pitch: CGFloat? = force2D ? 0.0 : nil
            navigationMapView.mapView.mapboxMap.setCamera(to: CameraOptions(
                center: initialLocation!,
                zoom: initialLocationZoom ?? 15,
                pitch: pitch
            ))
        }

        let style = currentMapStyle != nil ? StyleURI(rawValue: currentMapStyle!) : StyleURI.streets
        navigationMapView.mapView.mapboxMap.loadStyle(style!, completion: { [weak self] _ in
            guard let self = self else { return }
            navigationMapView.localizeLabels(locale: self.currentLocale)
            do {
                try navigationMapView.mapView.mapboxMap.localizeLabels(into: self.currentLocale)
            } catch {
                print("Failed to localize labels: \(error)")
            }
            self.addCustomRasterLayer()
            
            if self.force2D {
                navigationMapView.mapView.mapboxMap.setCamera(to: CameraOptions(pitch: 0.0))
            }
        })

        if newNavigationControllerRequired {
            let cancelButtons = navigationViewController.navigationView.bottomBannerContainerView.findViews(subclassOf: CancelButton.self)
            if let cancelButton = cancelButtons.first {
                cancelButton.addTarget(self, action: #selector(cancelButtonClicked), for: .touchUpInside)
            }

            navigationViewController.delegate = self
            addChild(navigationViewController)
            view.addSubview(navigationViewController.view)
            navigationViewController.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                navigationViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 0),
                navigationViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: 0),
                navigationViewController.view.topAnchor.constraint(equalTo: view.topAnchor, constant: 0),
                navigationViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: 0),
            ])
            didMove(toParent: self)
        }
        
        mapboxNavigation.tripSession().startActiveGuidance(with: navigationRoutes, startLegIndex: 0)
    }
}

extension ExpoMapboxNavigationViewController: NavigationViewControllerDelegate {
    func navigationViewController(_ navigationViewController: NavigationViewController, didRerouteAlong route: Route) {
        onRoutesLoaded?([
            "routes": [
                "mainRoute": convertRoute(route: route),
                "alternativeRoutes": []
            ]
        ])
    }

    func navigationViewControllerDidDismiss(
        _ navigationViewController: NavigationViewController,
        byCanceling canceled: Bool
    ) { }
}

extension UIView {
    func findViews<T: UIView>(subclassOf: T.Type) -> [T] {
        return recursiveSubviews.compactMap { $0 as? T }
    }

    var recursiveSubviews: [UIView] {
        return subviews + subviews.flatMap { $0.recursiveSubviews }
    }
}
