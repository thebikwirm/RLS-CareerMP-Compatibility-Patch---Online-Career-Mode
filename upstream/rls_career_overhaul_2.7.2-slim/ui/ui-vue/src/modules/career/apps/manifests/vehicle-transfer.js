export default {
  id: 'vehicle-transfer',
  name: 'CarGo',
  iconTile: 'rls-vehicle-transfer-icon.png',
  route: '/career/phone-vehicle-transfer',
  color: '#0b5fff',
  iconColor: '#ffffff',
  category: 'Jobs',
  storeTagline: 'Car Jockey',
  storeDescription: 'Car Jockey gigs anytime. Pay settles on each drop-off — no Employment hire required.',
  defaultPage: 0,
  defaultPosition: 8,
  notifications: [
    {
      key: 'vehicleTransfer.newJob',
      label: 'New Transfer',
      default: true,
      description: 'New transfer assignments',
      order: 0,
    },
  ],
}
