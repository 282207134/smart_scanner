#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdio.h>
#include <stdlib.h>

static unsigned little16(const UInt8 *p) { return p[0] | ((unsigned)p[1] << 8); }

// Read cached descriptors only. Never open, seize, reset, or configure USB devices.
int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s vendor-id product-id (decimal or 0xhex)\n", argv[0]);
    return 2;
  }
  unsigned vendor = (unsigned)strtoul(argv[1], NULL, 0);
  unsigned product = (unsigned)strtoul(argv[2], NULL, 0);
  io_iterator_t iterator;
  if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOUSBDeviceClassName), &iterator) != KERN_SUCCESS) return 1;
  io_service_t service;
  int found = 0;
  while ((service = IOIteratorNext(iterator))) {
    IOCFPlugInInterface **plugin = NULL;
    IOUSBDeviceInterface **device = NULL;
    SInt32 score = 0;
    IOReturn result = IOCreatePlugInInterfaceForService(service, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    IOObjectRelease(service);
    if (result != kIOReturnSuccess || plugin == NULL) continue;
    HRESULT query = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&device);
    (*plugin)->Release(plugin);
    if (query || device == NULL) continue;
    UInt16 actualVendor = 0, actualProduct = 0;
    (*device)->GetDeviceVendor(device, &actualVendor);
    (*device)->GetDeviceProduct(device, &actualProduct);
    if (actualVendor == vendor && actualProduct == product) {
      found = 1;
      UInt8 count = 0;
      (*device)->GetNumberOfConfigurations(device, &count);
      for (UInt8 config = 0; config < count; config++) {
        IOUSBConfigurationDescriptorPtr descriptor = NULL;
        result = (*device)->GetConfigurationDescriptorPtr(device, config, &descriptor);
        if (result != kIOReturnSuccess || descriptor == NULL) {
          fprintf(stderr, "configuration %u unavailable: 0x%x\n", config, result);
          continue;
        }
        const UInt8 *bytes = (const UInt8 *)descriptor;
        unsigned total = little16(bytes + 2);
        int videoStreaming = 0;
        const char *format = "unknown";
        for (unsigned offset = 0; offset + 3 <= total;) {
          const UInt8 *p = bytes + offset;
          unsigned length = p[0];
          if (length < 3 || offset + length > total) break;
          if (p[1] == 4 && length >= 9) videoStreaming = p[5] == 0x0e && p[6] == 2;
          if (videoStreaming && p[1] == 0x24) {
            if (p[2] == 1 && length >= 13) {
              printf("stream input: still method %u, trigger support %u, trigger usage %u\n", p[9], p[10], p[11]);
            }
            if (p[2] == 4) format = "uncompressed";
            if (p[2] == 6) format = "MJPEG";
            if (p[2] == 0x10) format = "frame-based";
            if ((p[2] == 5 || p[2] == 7 || p[2] == 0x11) && length >= 9) {
              printf("%s video: %ux%u\n", format, little16(p + 5), little16(p + 7));
            }
            if (p[2] == 3 && length >= 5) {
              for (unsigned i = 0; i < p[4] && 5 + 4 * (i + 1) <= length; i++) {
                printf("still: %ux%u\n", little16(p + 5 + i * 4), little16(p + 7 + i * 4));
              }
            }
          }
          offset += length;
        }
      }
    }
    (*device)->Release(device);
  }
  IOObjectRelease(iterator);
  return found ? 0 : 1;
}
