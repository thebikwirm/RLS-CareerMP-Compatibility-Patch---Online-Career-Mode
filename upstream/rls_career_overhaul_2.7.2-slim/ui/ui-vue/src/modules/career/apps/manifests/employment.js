import { icons } from '@/common/components/base'

export default {
  id: 'employment',
  name: 'Employment',
  icon: icons.cogs,
  iconTile: 'employment.png',
  route: '/career/phone-employment',
  color: '#1d4ed8',
  iconColor: '#ffffff',
  category: 'Jobs',
  storeTagline: 'Company driving jobs',
  storeDescription: 'Apply to companies, work assigned loads in issued trucks, and clock out from the yard.',
  hideFromStore: false,
  defaultPage: 0,
  defaultPosition: 14,
  notifications: [
    {
      key: 'employment.hired',
      label: 'Hired',
      default: true,
      description: 'Hired — report for your first assignment',
      order: 0,
    },
    {
      key: 'employment.shiftStarted',
      label: 'Shift Started',
      default: true,
      description: 'Company assignment issued',
      order: 1,
    },
    {
      key: 'employment.returnReady',
      label: 'Return Ready',
      default: true,
      description: 'Backhaul or return to yard',
      order: 2,
    },
    {
      key: 'employment.headhunter',
      label: 'Headhunter',
      default: true,
      description: 'Skill milestone — switch employers for new work',
      order: 3,
    },
    {
      key: 'employment.shiftEnded',
      label: 'Shift Ended',
      default: true,
      description: 'Clock out or left the job',
      order: 4,
    },
  ],
}
