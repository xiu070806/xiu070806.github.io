#import <Foundation/Foundation.h>
#import <Capacitor/Capacitor.h>
CAP_PLUGIN(TaximetLocationPlugin, "TaximetLocation",
  CAP_PLUGIN_METHOD(start, CAPPluginReturnPromise);
  CAP_PLUGIN_METHOD(stop, CAPPluginReturnPromise);
  CAP_PLUGIN_METHOD(setTripActive, CAPPluginReturnPromise);
  CAP_PLUGIN_METHOD(getLastLocation, CAPPluginReturnPromise);
  CAP_PLUGIN_METHOD(getBackgroundLocations, CAPPluginReturnPromise);
  CAP_PLUGIN_METHOD(ackBackgroundLocations, CAPPluginReturnPromise);
  CAP_PLUGIN_METHOD(clearBackgroundLocations, CAPPluginReturnPromise);
  CAP_PLUGIN_METHOD(status, CAPPluginReturnPromise);
)
