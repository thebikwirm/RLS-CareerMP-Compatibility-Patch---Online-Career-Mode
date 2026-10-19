import { icons } from '@/common/components/base'

export default {
  id: 'logistics',
  name: 'Job Broker',
  icon: icons.cogs,
  iconTile: 'job-broker.svg',
  route: '/career/phone-logistics',
  color: '#2b6cb0',
  iconColor: '#ffffff',
  category: 'Jobs',
  storeTagline: 'Find. Reserve. Haul.',
  storeDescription: 'Find independent hauling work, reserve loads, plan your route and borrow equipment from the central depot.',
  defaultPage: 0,
  defaultPosition: 11,
  notifications: [
    {
      key: 'logistics.cargoAbandoned',
      label: 'Cargo Abandoned',
      default: true,
      description: 'Abandoned cargo, penalty',
      order: 0,
    },
  ],
  unlockCondition: async (luaBridge) => {
    try {
      await luaBridge.extensions.load('ui_phone_layout')
      const fromLayout = await luaBridge.ui_phone_layout.getCareerActive()
      if (fromLayout) return true
    } catch { }
    try {
      return await luaBridge.career_career.isActive()
    } catch {
      return false
    }
  },
}
