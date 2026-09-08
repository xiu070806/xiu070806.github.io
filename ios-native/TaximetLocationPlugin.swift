import Foundation
import UIKit
import CoreLocation
import Capacitor

@objc(TaximetLocationPlugin)
public class TaximetLocationPlugin: CAPPlugin, CLLocationManagerDelegate {
    private let manager=CLLocationManager()
    private let q=DispatchQueue(label:"com.taximet.pro.location.queue",qos:.utility)
    private let tripKey="TaximetLocation.tripActive"
    private let nextKey="TaximetLocation.nextSequence"
    private let ackKey="TaximetLocation.ackSequence"
    private var tripActive=false
    private var bgSession:AnyObject?

    private lazy var queueURL:URL={
        let base=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        let dir=base.appendingPathComponent("TAXIMETPRO",isDirectory:true)
        try? FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        return dir.appendingPathComponent("location-queue.jsonl")
    }()

    public override func load(){
        super.load();q.sync{}
        manager.delegate=self;configure()
        tripActive=UserDefaults.standard.bool(forKey:tripKey)
        if tripActive{startServices()}
    }

    @objc public func start(_ call:CAPPluginCall){
        tripActive=true;UserDefaults.standard.set(true,forKey:tripKey)
        startServices();call.resolve(["status":"STARTED","tripActive":true])
    }

    @objc public func stop(_ call:CAPPluginCall){
        tripActive=false;UserDefaults.standard.set(false,forKey:tripKey)
        manager.stopUpdatingLocation();manager.stopMonitoringSignificantLocationChanges()
        endSession();call.resolve(["status":"STOPPED","tripActive":false])
    }

    @objc public func setTripActive(_ call:CAPPluginCall){
        let active=call.getBool("active") ?? false
        tripActive=active;UserDefaults.standard.set(active,forKey:tripKey)
        if active{startServices()}else{
            manager.stopUpdatingLocation();manager.stopMonitoringSignificantLocationChanges();endSession()
        }
        call.resolve(["tripActive":active])
    }

    @objc public func getLastLocation(_ call:CAPPluginCall){
        if let l=manager.location{call.resolve(payload(l,seq:0))}else{call.resolve([:])}
    }

    @objc public func getBackgroundLocations(_ call:CAPPluginCall){
        call.resolve(["locations":q.sync{readQueue()}])
    }

    @objc public func ackBackgroundLocations(_ call:CAPPluginCall){
        let requested=call.getInt("sequence") ?? 0
        call.resolve(["ackSequence":q.sync{compact(upTo:requested)}])
    }

    @objc public func clearBackgroundLocations(_ call:CAPPluginCall){
        let n=q.sync{let n=readQueue().count;try? FileManager.default.removeItem(at:queueURL);return n}
        let next=UserDefaults.standard.integer(forKey:nextKey)
        UserDefaults.standard.set(max(0,next-1),forKey:ackKey)
        call.resolve(["cleared":n])
    }

    @objc public func status(_ call:CAPPluginCall){
        let n=q.sync{readQueue().count}
        call.resolve(["tripActive":tripActive,"authorization":manager.authorizationStatus.rawValue,"queueCount":n,"ackSequence":UserDefaults.standard.integer(forKey:ackKey)])
    }

    private func configure(){
        manager.desiredAccuracy=kCLLocationAccuracyBestForNavigation
        manager.distanceFilter=kCLLocationDistanceFilterNone
        manager.activityType=.automotiveNavigation
        manager.pausesLocationUpdatesAutomatically=false
        manager.allowsBackgroundLocationUpdates=true
        if #available(iOS 11.0,*){manager.showsBackgroundLocationIndicator=true}
    }

    private func startServices(){
        configure()
        switch manager.authorizationStatus{
        case .notDetermined: manager.requestAlwaysAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        case .authorizedAlways:
            beginSession()
            manager.startUpdatingLocation()
            manager.startMonitoringSignificantLocationChanges()
        default:
            notifyListeners("locationError",data:["code":1,"message":"Location permission is not Always authorized"])
        }
    }

    private func beginSession(){
        guard #available(iOS 17.0,*) else{return}
        DispatchQueue.main.async{[weak self] in
            guard let self,self.bgSession==nil else{return}
            self.bgSession=BackgroundSessionBox()
        }
    }

    private func endSession(){
        guard #available(iOS 17.0,*) else{return}
        DispatchQueue.main.async{[weak self] in
            guard let self else{return}
            (self.bgSession as? BackgroundSessionBox)?.session.invalidate()
            self.bgSession=nil
        }
    }

    public func locationManagerDidChangeAuthorization(_ manager:CLLocationManager){
        guard tripActive else{return}
        startServices()
    }

    public func locationManager(_ manager:CLLocationManager,didUpdateLocations locations:[CLLocation]){
        guard tripActive else{return}
        let background=UIApplication.shared.applicationState != .active
        for l in locations{
            guard l.horizontalAccuracy>=0,l.horizontalAccuracy<=100 else{continue}
            if background{
                let seq=q.sync{append(l)}
                if seq>0{DispatchQueue.main.async{[weak self] in
                    self?.notifyListeners("locationUpdate",data:self?.payload(l,seq:seq) ?? [:])
                }}
            }else{
                DispatchQueue.main.async{[weak self] in
                    self?.notifyListeners("locationUpdate",data:self?.payload(l,seq:0) ?? [:])
                }
            }
        }
    }

    public func locationManager(_ manager:CLLocationManager,didFailWithError error:Error){
        DispatchQueue.main.async{[weak self] in
            self?.notifyListeners("locationError",data:["code":2,"message":error.localizedDescription])
        }
    }

    private func append(_ l:CLLocation)->Int{
        let seq=UserDefaults.standard.integer(forKey:nextKey)+1
        UserDefaults.standard.set(seq,forKey:nextKey)
        guard let d=try? JSONSerialization.data(withJSONObject:payload(l,seq:seq),options:[]) else{return 0}
        var line=d;line.append(0x0A)
        if !FileManager.default.fileExists(atPath:queueURL.path){FileManager.default.createFile(atPath:queueURL.path,contents:nil)}
        do{
            let h=try FileHandle(forWritingTo:queueURL)
            try h.seekToEnd();try h.write(contentsOf:line);try h.synchronize();try h.close()
            return seq
        }catch{return 0}
    }

    private func readQueue()->[[String:Any]]{
        guard let d=try? Data(contentsOf:queueURL),!d.isEmpty else{return []}
        let ack=UserDefaults.standard.integer(forKey:ackKey)
        return d.split(separator:0x0A).compactMap{line in
            guard let obj=try? JSONSerialization.jsonObject(with:Data(line)),let dict=obj as? [String:Any] else{return nil}
            let seq=(dict["seq"] as? NSNumber)?.intValue ?? 0
            return seq>ack ? dict : nil
        }
    }

    private func compact(upTo requested:Int)->Int{
        let ack=UserDefaults.standard.integer(forKey:ackKey)
        guard requested>ack else{return ack}
        let items=readQueue()
        let maxSeq=items.map{($0["seq"] as? NSNumber)?.intValue ?? 0}.max() ?? ack
        let target=min(requested,maxSeq)
        guard target>ack else{return ack}
        let remain=items.filter{(($0["seq"] as? NSNumber)?.intValue ?? 0)>target}
        if remain.isEmpty{try? FileManager.default.removeItem(at:queueURL)}
        else{
            var d=Data()
            for item in remain{if var line=try? JSONSerialization.data(withJSONObject:item,options:[]){line.append(0x0A);d.append(line)}}
            try? d.write(to:queueURL,options:.atomic)
        }
        UserDefaults.standard.set(target,forKey:ackKey)
        return target
    }

    private func payload(_ l:CLLocation,seq:Int)->[String:Any]{
        ["seq":seq,"latitude":l.coordinate.latitude,"longitude":l.coordinate.longitude,"accuracy":l.horizontalAccuracy,"speed":l.speed>=0 ? l.speed : NSNull(),"heading":l.course>=0 ? l.course : NSNull(),"timestamp":l.timestamp.timeIntervalSince1970*1000]
    }
}

@available(iOS 17.0,*)
private final class BackgroundSessionBox:NSObject{
    let session=CLBackgroundActivitySession()
}
