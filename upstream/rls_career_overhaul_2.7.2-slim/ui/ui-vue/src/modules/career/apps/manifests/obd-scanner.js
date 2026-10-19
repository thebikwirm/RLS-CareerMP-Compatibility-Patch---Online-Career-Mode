export default {
  id: 'obd-scanner',
  name: 'OBD Scanner',
  iconImage: '/ui/entrypoints/main/tiles/rls-obd-scanner.svg',
  iconImageFit: 'contain',
  route: '/career/phone-obd-scanner',
  color: '#101923',
  iconColor: '#50e3a4',
  category: 'Tools',
  storeTagline: 'Live vehicle diagnostics and maintenance data',
  storeDescription:
    'View engine, thermal, drivetrain and service information from the current vehicle, with low engine oil alerts while driving.',
  notifications: [
    {
      key: 'obdScanner.lowOil',
      label: 'Low engine oil',
      description: 'Warn when engine oil is low and when it reaches a critical level.',
      default: true,
    },
  ],
  defaultPage: 0,
  defaultPosition: 16,
}
