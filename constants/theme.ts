export const colors = {
  brand: { primary: '#145B7A', navy: '#0B3449', teal: '#1B9AAA', aqua: '#53C6C8' },
  background: { main: '#F5F8FA', surface: '#FFFFFF', subtle: '#EAF1F5' },
  text: { primary: '#172B3A', secondary: '#617586', inverse: '#FFFFFF' },
  border: '#DCE5EB',
  status: {
    success: { main: '#168A55', background: '#E8F6EF', text: '#146C43' },
    warning: { main: '#D98B16', background: '#FFF4DE', text: '#946200' },
    danger: { main: '#D64545', background: '#FDECEC', text: '#B42318' },
    info: { main: '#2878C7', background: '#EAF4FF', text: '#175FA5' },
  },
} as const;

export const spacing = { xs: 4, sm: 8, md: 16, lg: 24, xl: 32, xxl: 40 } as const;
export const radius = { sm: 8, md: 12, lg: 16, pill: 999 } as const;
