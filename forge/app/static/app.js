/* ============================================================
   BareIgnite Forge - Web UI Application
   Vue 3 Composition API + Hash Router
   ============================================================ */

const { createApp, ref, reactive, computed, watch, onMounted, onUnmounted, nextTick } = Vue;

/* ============================================================
   SVG Icon Definitions (inline, no external deps)
   ============================================================ */
const ICONS = {
  dashboard: '<svg viewBox="0 0 24 24"><rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/></svg>',
  images:    '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="16"/><line x1="8" y1="12" x2="16" y2="12"/></svg>',
  build:     '<svg viewBox="0 0 24 24"><path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z"/></svg>',
  updates:   '<svg viewBox="0 0 24 24"><polyline points="23 4 23 10 17 10"/><polyline points="1 20 1 14 7 14"/><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/></svg>',
  history:   '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg>',
  sun:       '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="5"/><line x1="12" y1="1" x2="12" y2="3"/><line x1="12" y1="21" x2="12" y2="23"/><line x1="4.22" y1="4.22" x2="5.64" y2="5.64"/><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"/><line x1="1" y1="12" x2="3" y2="12"/><line x1="21" y1="12" x2="23" y2="12"/><line x1="4.22" y1="19.78" x2="5.64" y2="18.36"/><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"/></svg>',
  moon:      '<svg viewBox="0 0 24 24"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/></svg>',
  menu:      '<svg viewBox="0 0 24 24"><line x1="3" y1="12" x2="21" y2="12"/><line x1="3" y1="6" x2="21" y2="6"/><line x1="3" y1="18" x2="21" y2="18"/></svg>',
  x:         '<svg viewBox="0 0 24 24"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>',
  check:     '<svg viewBox="0 0 24 24"><polyline points="20 6 9 17 4 12"/></svg>',
  download:  '<svg viewBox="0 0 24 24"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>',
  upload:    '<svg viewBox="0 0 24 24"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="17 8 12 3 7 8"/><line x1="12" y1="3" x2="12" y2="15"/></svg>',
  trash:     '<svg viewBox="0 0 24 24"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/></svg>',
  refresh:   '<svg viewBox="0 0 24 24"><polyline points="23 4 23 10 17 10"/><path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10"/></svg>',
  spinner:   '<svg viewBox="0 0 24 24"><path d="M12 2a10 10 0 0 1 10 10" stroke-linecap="round"/></svg>',
  disc:      '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="10"/><circle cx="12" cy="12" r="3"/></svg>',
  usb:       '<svg viewBox="0 0 24 24"><rect x="6" y="2" width="12" height="20" rx="2"/><line x1="10" y1="6" x2="10" y2="10"/><line x1="14" y1="6" x2="14" y2="10"/></svg>',
  server:    '<svg viewBox="0 0 24 24"><rect x="2" y="2" width="20" height="8" rx="2"/><rect x="2" y="14" width="20" height="8" rx="2"/><line x1="6" y1="6" x2="6.01" y2="6"/><line x1="6" y1="18" x2="6.01" y2="18"/></svg>',
  hdd:       '<svg viewBox="0 0 24 24"><line x1="22" y1="12" x2="2" y2="12"/><path d="M5.45 5.11L2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/><line x1="6" y1="16" x2="6.01" y2="16"/><line x1="10" y1="16" x2="10.01" y2="16"/></svg>',
  play:      '<svg viewBox="0 0 24 24"><polygon points="5 3 19 12 5 21 5 3"/></svg>',
  folder:    '<svg viewBox="0 0 24 24"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg>',
  alertCircle: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/></svg>',
  checkCircle: '<svg viewBox="0 0 24 24"><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/></svg>',
  xCircle:   '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="10"/><line x1="15" y1="9" x2="9" y2="15"/><line x1="9" y1="9" x2="15" y2="15"/></svg>',
  info:      '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="10"/><line x1="12" y1="16" x2="12" y2="12"/><line x1="12" y1="8" x2="12.01" y2="8"/></svg>',
  arrowRight:'<svg viewBox="0 0 24 24"><line x1="5" y1="12" x2="19" y2="12"/><polyline points="12 5 19 12 12 19"/></svg>',
  arrowLeft: '<svg viewBox="0 0 24 24"><line x1="19" y1="12" x2="5" y2="12"/><polyline points="12 19 5 12 12 5"/></svg>',
  package:   '<svg viewBox="0 0 24 24"><line x1="16.5" y1="9.4" x2="7.5" y2="4.21"/><path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"/><polyline points="3.27 6.96 12 12.01 20.73 6.96"/><line x1="12" y1="22.08" x2="12" y2="12"/></svg>',
  zap:       '<svg viewBox="0 0 24 24"><polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"/></svg>',
  activity:  '<svg viewBox="0 0 24 24"><polyline points="22 12 18 12 15 21 9 3 6 12 2 12"/></svg>',
};


/* ============================================================
   API Service Layer
   ============================================================ */
const API_BASE = '/api';

class ApiError extends Error {
  constructor(message, status, data) {
    super(message);
    this.status = status;
    this.data = data;
  }
}

const api = {
  async request(method, path, options = {}) {
    const url = `${API_BASE}${path}`;
    const config = {
      method,
      headers: {},
    };

    if (options.body && !(options.body instanceof FormData)) {
      config.headers['Content-Type'] = 'application/json';
      config.body = JSON.stringify(options.body);
    } else if (options.body) {
      config.body = options.body;
    }

    if (options.signal) config.signal = options.signal;

    try {
      const res = await fetch(url, config);
      if (!res.ok) {
        let data = null;
        try { data = await res.json(); } catch (e) { /* ignore */ }
        throw new ApiError(
          data?.detail || data?.message || `Request failed (${res.status})`,
          res.status,
          data
        );
      }
      // Handle 204 No Content
      if (res.status === 204) return null;
      const ct = res.headers.get('content-type') || '';
      if (ct.includes('application/json')) return res.json();
      return res;
    } catch (err) {
      if (err instanceof ApiError) throw err;
      throw new ApiError(err.message || 'Network error', 0, null);
    }
  },

  get(path, opts)       { return this.request('GET', path, opts); },
  post(path, body, opts){ return this.request('POST', path, { body, ...opts }); },
  put(path, body, opts) { return this.request('PUT', path, { body, ...opts }); },
  del(path, opts)       { return this.request('DELETE', path, opts); },

  // -- Dashboard --
  getDashboard()       { return this.get('/dashboard'); },
  getSystemStatus()    { return this.get('/status'); },

  // -- Images (Cache) --
  getImages()          { return this.get('/images'); },
  deleteImage(id)      { return this.del(`/images/${id}`); },
  downloadImage(id)    { return this.get(`/images/${id}/download`); },
  uploadImage(formData, signal) {
    return this.post('/images/upload', formData, { signal });
  },

  // -- Builds --
  getBuilds()          { return this.get('/builds'); },
  getBuild(id)         { return this.get(`/builds/${id}`); },
  startBuild(config)   { return this.post('/builds', config); },
  cancelBuild(id)      { return this.post(`/builds/${id}/cancel`); },
  downloadBuild(id) {
    window.open(`${API_BASE}/builds/${id}/download`, '_blank');
  },

  // -- Updates --
  getUpdates()         { return this.get('/updates'); },
  checkUpdates()       { return this.post('/updates/check'); },
  applyUpdate(comp)    { return this.post('/updates/apply', { component: comp }); },

  // -- OS definitions --
  getOsDefinitions()   { return this.get('/os'); },
};


/* ============================================================
   Helpers
   ============================================================ */
function formatBytes(bytes) {
  if (bytes === 0 || bytes == null) return '0 B';
  const k = 1024;
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return parseFloat((bytes / Math.pow(k, i)).toFixed(1)) + ' ' + units[i];
}

function formatDate(str) {
  if (!str) return '-';
  const d = new Date(str);
  if (isNaN(d)) return str;
  return d.toLocaleString('en-US', {
    year: 'numeric', month: 'short', day: 'numeric',
    hour: '2-digit', minute: '2-digit'
  });
}

function formatDuration(seconds) {
  if (!seconds && seconds !== 0) return '-';
  if (seconds < 60) return `${seconds}s`;
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  if (m < 60) return `${m}m ${s}s`;
  const h = Math.floor(m / 60);
  return `${h}h ${m % 60}m`;
}

function statusBadgeClass(status) {
  const map = {
    success:   'badge-success',
    completed: 'badge-success',
    running:   'badge-running',
    building:  'badge-running',
    failed:    'badge-failed',
    error:     'badge-failed',
    pending:   'badge-pending',
    queued:    'badge-pending',
    warning:   'badge-warning',
    cancelled: 'badge-warning',
    'up-to-date': 'badge-success',
    'update-available': 'badge-info',
  };
  return map[status] || 'badge-pending';
}

function debounce(fn, ms) {
  let timer;
  return function (...args) {
    clearTimeout(timer);
    timer = setTimeout(() => fn.apply(this, args), ms);
  };
}


/* ============================================================
   Toast System (reactive)
   ============================================================ */
const toasts = reactive([]);
let toastIdCounter = 0;

function addToast(type, title, message = '', duration = 5000) {
  const id = ++toastIdCounter;
  toasts.push({ id, type, title, message, removing: false });
  if (duration > 0) {
    setTimeout(() => removeToast(id), duration);
  }
  return id;
}

function removeToast(id) {
  const t = toasts.find(t => t.id === id);
  if (t) {
    t.removing = true;
    setTimeout(() => {
      const i = toasts.findIndex(t => t.id === id);
      if (i !== -1) toasts.splice(i, 1);
    }, 260);
  }
}

const toast = {
  success: (title, msg) => addToast('success', title, msg),
  error:   (title, msg) => addToast('error', title, msg, 8000),
  warning: (title, msg) => addToast('warning', title, msg, 6000),
  info:    (title, msg) => addToast('info', title, msg),
};


/* ============================================================
   Mock Data (used when backend is unavailable)
   ============================================================ */
const MOCK = {
  dashboard: {
    cache_usage: { used: 8.7 * 1024**3, total: 50 * 1024**3, items: 12 },
    recent_builds: [
      { id: 'b001', os: 'Rocky Linux 9.4', media: 'USB', status: 'completed', created_at: '2026-02-27T10:30:00Z', size: 2.1*1024**3, duration: 185 },
      { id: 'b002', os: 'Ubuntu 24.04', media: 'ISO', status: 'running', created_at: '2026-02-27T11:15:00Z', size: null, duration: null, progress: 67 },
      { id: 'b003', os: 'ESXi 8.0', media: 'ISO', status: 'failed', created_at: '2026-02-26T16:42:00Z', size: null, duration: 45, error: 'Missing vmvisor image' },
    ],
    system_status: {
      services: [
        { name: 'Forge API', status: 'running' },
        { name: 'Cache Store', status: 'running' },
        { name: 'Build Engine', status: 'running' },
      ],
      version: '0.1.0',
      uptime: '2d 5h 33m',
    }
  },

  images: [
    { id: 'img001', name: 'Rocky-9.4-x86_64-dvd.iso',    os: 'Rocky Linux', version: '9.4', arch: 'x86_64', size: 10.8*1024**3, cached_at: '2026-02-20T08:00:00Z', type: 'dvd' },
    { id: 'img002', name: 'Rocky-9.4-x86_64-boot.iso',    os: 'Rocky Linux', version: '9.4', arch: 'x86_64', size: 0.9*1024**3,  cached_at: '2026-02-20T08:05:00Z', type: 'boot' },
    { id: 'img003', name: 'ubuntu-24.04.1-live-server-amd64.iso', os: 'Ubuntu', version: '24.04', arch: 'x86_64', size: 2.6*1024**3,  cached_at: '2026-02-22T14:00:00Z', type: 'live' },
    { id: 'img004', name: 'VMware-VMvisor-Installer-8.0U3-24280767.x86_64.iso', os: 'ESXi', version: '8.0U3', arch: 'x86_64', size: 0.63*1024**3, cached_at: '2026-02-25T09:20:00Z', type: 'installer' },
    { id: 'img005', name: 'CentOS-7-x86_64-DVD-2009.iso', os: 'CentOS', version: '7.9', arch: 'x86_64', size: 4.4*1024**3, cached_at: '2026-02-18T11:30:00Z', type: 'dvd' },
    { id: 'img006', name: 'Win2022_EN_x64.iso',           os: 'Windows Server', version: '2022', arch: 'x86_64', size: 5.1*1024**3,  cached_at: '2026-02-24T16:00:00Z', type: 'installer' },
  ],

  builds: [
    { id: 'b001', os: 'Rocky Linux 9.4', media: 'USB',  status: 'completed', created_at: '2026-02-27T10:30:00Z', size: 2.1*1024**3,  duration: 185 },
    { id: 'b002', os: 'Ubuntu 24.04',    media: 'ISO',  status: 'running',   created_at: '2026-02-27T11:15:00Z', size: null,          duration: null,  progress: 67 },
    { id: 'b003', os: 'ESXi 8.0',        media: 'ISO',  status: 'failed',    created_at: '2026-02-26T16:42:00Z', size: null,          duration: 45,    error: 'Missing vmvisor image' },
    { id: 'b004', os: 'CentOS 7.9',      media: 'USB',  status: 'completed', created_at: '2026-02-25T09:10:00Z', size: 4.8*1024**3,  duration: 312 },
    { id: 'b005', os: 'Rocky Linux 9.4', media: 'ISO',  status: 'completed', created_at: '2026-02-24T14:20:00Z', size: 10.9*1024**3, duration: 95 },
    { id: 'b006', os: 'Windows Server 2022', media: 'USB', status: 'completed', created_at: '2026-02-23T08:05:00Z', size: 6.2*1024**3, duration: 420 },
    { id: 'b007', os: 'Ubuntu 22.04',    media: 'ISO',  status: 'cancelled', created_at: '2026-02-22T17:35:00Z', size: null,         duration: 22 },
  ],

  updates: {
    last_checked: '2026-02-27T11:00:00Z',
    components: [
      { name: 'syslinux',      current: '6.03', latest: '6.03',  status: 'up-to-date' },
      { name: 'shim-x64',      current: '15.8', latest: '15.8',  status: 'up-to-date' },
      { name: 'grub2-efi-x64', current: '2.06', latest: '2.12',  status: 'update-available' },
      { name: 'grub2-efi-aa64',current: '2.06', latest: '2.12',  status: 'update-available' },
      { name: 'wimboot',       current: '2.7.3',latest: '2.7.6', status: 'update-available' },
      { name: 'iPXE',          current: '1.21.1',latest: '1.21.1',status: 'up-to-date' },
      { name: 'nginx',         current: '1.24.0',latest: '1.24.0',status: 'up-to-date' },
      { name: 'dnsmasq',       current: '2.89', latest: '2.90',  status: 'update-available' },
    ]
  },

  os_definitions: [
    { id: 'rocky9',   name: 'Rocky Linux',        version: '9.x',  family: 'rhel', arch: ['x86_64','aarch64'], icon: 'server' },
    { id: 'rocky8',   name: 'Rocky Linux',        version: '8.x',  family: 'rhel', arch: ['x86_64'], icon: 'server' },
    { id: 'centos7',  name: 'CentOS',             version: '7.x',  family: 'rhel', arch: ['x86_64'], icon: 'server' },
    { id: 'rhel9',    name: 'RHEL',               version: '9.x',  family: 'rhel', arch: ['x86_64','aarch64'], icon: 'server' },
    { id: 'ubuntu2404',name:'Ubuntu Server',       version: '24.04',family: 'debian',arch: ['x86_64','aarch64'],icon: 'server' },
    { id: 'ubuntu2204',name:'Ubuntu Server',       version: '22.04',family: 'debian',arch: ['x86_64'], icon: 'server' },
    { id: 'ubuntu2004',name:'Ubuntu Server',       version: '20.04',family: 'debian',arch: ['x86_64'], icon: 'server' },
    { id: 'esxi8',    name: 'VMware ESXi',        version: '8.x',  family: 'esxi', arch: ['x86_64'], icon: 'server' },
    { id: 'esxi7',    name: 'VMware ESXi',        version: '7.x',  family: 'esxi', arch: ['x86_64'], icon: 'server' },
    { id: 'win2022',  name: 'Windows Server',     version: '2022', family: 'windows',arch: ['x86_64'],icon: 'server' },
    { id: 'win2019',  name: 'Windows Server',     version: '2019', family: 'windows',arch: ['x86_64'],icon: 'server' },
    { id: 'kylinv10', name: 'Kylin V10',          version: 'V10',  family: 'rhel', arch: ['x86_64','aarch64'], icon: 'server' },
  ],
};


/* ============================================================
   Data fetching wrapper -- falls back to mock data
   ============================================================ */
let useMock = false;

async function fetchOr(apiCall, mockKey) {
  try {
    const data = await apiCall();
    return data;
  } catch (err) {
    if (!useMock) {
      useMock = true;
      console.warn('Forge API not available, using demo data.');
    }
    // Navigate nested mock keys like "dashboard"
    const keys = mockKey.split('.');
    let val = MOCK;
    for (const k of keys) val = val[k];
    return JSON.parse(JSON.stringify(val)); // deep clone
  }
}


/* ============================================================
   Vue Application
   ============================================================ */
const app = createApp({
  setup() {
    // --- Theme ---
    const savedTheme = localStorage.getItem('forge-theme') || 'dark';
    const darkMode = ref(savedTheme === 'dark');

    watch(darkMode, (v) => {
      document.documentElement.setAttribute('data-theme', v ? 'dark' : 'light');
      localStorage.setItem('forge-theme', v ? 'dark' : 'light');
    }, { immediate: true });

    function toggleTheme() { darkMode.value = !darkMode.value; }

    // --- Routing (hash-based) ---
    const routes = ['dashboard', 'images', 'build', 'updates', 'history'];
    const currentRoute = ref('dashboard');

    function setRoute(r) {
      if (routes.includes(r)) {
        currentRoute.value = r;
        window.location.hash = r;
        closeSidebar();
      }
    }

    function handleHashChange() {
      const hash = window.location.hash.slice(1) || 'dashboard';
      if (routes.includes(hash)) currentRoute.value = hash;
      else currentRoute.value = 'dashboard';
    }

    onMounted(() => {
      window.addEventListener('hashchange', handleHashChange);
      handleHashChange();
    });
    onUnmounted(() => {
      window.removeEventListener('hashchange', handleHashChange);
    });

    // --- Sidebar mobile ---
    const sidebarOpen = ref(false);
    function toggleSidebar() { sidebarOpen.value = !sidebarOpen.value; }
    function closeSidebar()  { sidebarOpen.value = false; }

    // --- Page title ---
    const pageTitle = computed(() => {
      const map = {
        dashboard: 'Dashboard',
        images: 'Image Manager',
        build: 'Build Media',
        updates: 'Update Center',
        history: 'Build History',
      };
      return map[currentRoute.value] || 'Dashboard';
    });

    // --- Navigation items ---
    const navItems = [
      { id: 'dashboard', label: 'Dashboard', icon: 'dashboard' },
      { id: 'images',    label: 'Images',    icon: 'disc' },
      { id: 'build',     label: 'Build',     icon: 'build' },
      { id: 'updates',   label: 'Updates',   icon: 'updates' },
      { id: 'history',   label: 'History',   icon: 'history' },
    ];

    // === DASHBOARD ===
    const dashLoading = ref(false);
    const dashData = reactive({
      cache_usage: { used: 0, total: 0, items: 0 },
      recent_builds: [],
      system_status: { services: [], version: '-', uptime: '-' },
    });

    async function loadDashboard() {
      dashLoading.value = true;
      try {
        const data = await fetchOr(() => api.getDashboard(), 'dashboard');
        Object.assign(dashData, data);
      } catch (e) {
        toast.error('Dashboard Error', e.message);
      }
      dashLoading.value = false;
    }

    const cachePercent = computed(() => {
      if (!dashData.cache_usage.total) return 0;
      return Math.round((dashData.cache_usage.used / dashData.cache_usage.total) * 100);
    });

    const cacheBarColor = computed(() => {
      if (cachePercent.value > 90) return 'red';
      if (cachePercent.value > 70) return 'orange';
      return 'green';
    });

    // === IMAGES ===
    const imgLoading = ref(false);
    const images = ref([]);
    const imgDragover = ref(false);
    const imgUploading = ref(false);
    const imgUploadProgress = ref(0);
    const imgUploadAbort = ref(null);
    const imgDeleteConfirm = ref(null);

    async function loadImages() {
      imgLoading.value = true;
      try {
        images.value = await fetchOr(() => api.getImages(), 'images');
      } catch (e) {
        toast.error('Image Error', e.message);
      }
      imgLoading.value = false;
    }

    async function deleteImage(img) {
      imgDeleteConfirm.value = null;
      try {
        if (!useMock) await api.deleteImage(img.id);
        else images.value = images.value.filter(i => i.id !== img.id);
        toast.success('Image Deleted', `${img.name} has been removed from cache.`);
        if (!useMock) await loadImages();
      } catch (e) {
        toast.error('Delete Failed', e.message);
      }
    }

    function handleImageDrop(e) {
      imgDragover.value = false;
      const files = e.dataTransfer?.files;
      if (files?.length) uploadImageFiles(files);
    }

    function handleImageFileSelect(e) {
      const files = e.target?.files;
      if (files?.length) uploadImageFiles(files);
      e.target.value = '';
    }

    async function uploadImageFiles(files) {
      for (const file of files) {
        imgUploading.value = true;
        imgUploadProgress.value = 0;
        try {
          if (useMock) {
            // Simulate upload progress
            for (let p = 0; p <= 100; p += 5) {
              imgUploadProgress.value = p;
              await new Promise(r => setTimeout(r, 80));
            }
            images.value.push({
              id: 'img' + Date.now(),
              name: file.name,
              os: 'Unknown',
              version: '-',
              arch: 'x86_64',
              size: file.size,
              cached_at: new Date().toISOString(),
              type: 'imported',
            });
            toast.success('Import Complete', `${file.name} imported successfully.`);
          } else {
            const fd = new FormData();
            fd.append('file', file);
            const ctrl = new AbortController();
            imgUploadAbort.value = ctrl;
            await api.uploadImage(fd, ctrl.signal);
            toast.success('Import Complete', `${file.name} imported successfully.`);
            await loadImages();
          }
        } catch (e) {
          if (e.name !== 'AbortError') {
            toast.error('Import Failed', e.message);
          }
        }
        imgUploading.value = false;
        imgUploadProgress.value = 0;
        imgUploadAbort.value = null;
      }
    }

    function cancelUpload() {
      if (imgUploadAbort.value) {
        imgUploadAbort.value.abort();
        imgUploading.value = false;
        imgUploadProgress.value = 0;
        toast.info('Upload Cancelled', 'File upload was cancelled.');
      }
    }

    const totalCacheSize = computed(() => {
      return images.value.reduce((sum, img) => sum + (img.size || 0), 0);
    });

    // === BUILD WIZARD ===
    const buildSteps = ['Select OS', 'Media Type', 'Configure', 'Review', 'Build'];
    const buildStep = ref(0);
    const buildLoading = ref(false);
    const osDefinitions = ref([]);

    const buildConfig = reactive({
      os: null,
      media: null,
      label: '',
      hostname: 'bareignite',
      include_drivers: true,
      include_firmware: false,
      kickstart_url: '',
      autoinstall_url: '',
      custom_packages: '',
      pxe_boot: true,
      uefi_only: false,
    });

    const buildProgress = reactive({
      active: false,
      id: null,
      status: 'pending',
      percent: 0,
      message: '',
      error: '',
    });

    let buildPollTimer = null;

    async function loadOsDefinitions() {
      try {
        osDefinitions.value = await fetchOr(() => api.getOsDefinitions(), 'os_definitions');
      } catch (e) {
        toast.error('Error', 'Failed to load OS definitions');
      }
    }

    function selectOs(os) {
      buildConfig.os = os;
    }

    function selectMedia(media) {
      buildConfig.media = media;
    }

    function nextBuildStep() {
      if (buildStep.value === 0 && !buildConfig.os) {
        toast.warning('Select OS', 'Please select an operating system to continue.');
        return;
      }
      if (buildStep.value === 1 && !buildConfig.media) {
        toast.warning('Select Media', 'Please select a media type to continue.');
        return;
      }
      if (buildStep.value < buildSteps.length - 1) {
        buildStep.value++;
      }
    }

    function prevBuildStep() {
      if (buildStep.value > 0) buildStep.value--;
    }

    function resetBuild() {
      buildStep.value = 0;
      buildConfig.os = null;
      buildConfig.media = null;
      buildConfig.label = '';
      buildConfig.hostname = 'bareignite';
      buildConfig.include_drivers = true;
      buildConfig.include_firmware = false;
      buildConfig.kickstart_url = '';
      buildConfig.autoinstall_url = '';
      buildConfig.custom_packages = '';
      buildConfig.pxe_boot = true;
      buildConfig.uefi_only = false;
      buildProgress.active = false;
      buildProgress.id = null;
      buildProgress.status = 'pending';
      buildProgress.percent = 0;
      buildProgress.message = '';
      buildProgress.error = '';
      if (buildPollTimer) clearInterval(buildPollTimer);
    }

    async function startBuild() {
      buildStep.value = 4; // Move to Build step
      buildProgress.active = true;
      buildProgress.status = 'running';
      buildProgress.percent = 0;
      buildProgress.message = 'Initializing build...';
      buildProgress.error = '';

      if (useMock) {
        // Simulate build progress
        const steps = [
          { p: 10, msg: 'Preparing workspace...' },
          { p: 25, msg: 'Extracting source ISO...' },
          { p: 40, msg: 'Injecting kickstart configuration...' },
          { p: 55, msg: 'Copying PXE boot files...' },
          { p: 70, msg: 'Building file system...' },
          { p: 85, msg: 'Creating bootable media...' },
          { p: 95, msg: 'Verifying checksums...' },
          { p: 100, msg: 'Build complete!' },
        ];
        for (const step of steps) {
          await new Promise(r => setTimeout(r, 600 + Math.random() * 400));
          buildProgress.percent = step.p;
          buildProgress.message = step.msg;
        }
        buildProgress.status = 'completed';
        buildProgress.id = 'b' + Date.now();
        toast.success('Build Complete', `${buildConfig.os.name} ${buildConfig.os.version} ${buildConfig.media} ready.`);
      } else {
        try {
          const result = await api.startBuild({
            os_id: buildConfig.os.id,
            media: buildConfig.media,
            label: buildConfig.label,
            hostname: buildConfig.hostname,
            include_drivers: buildConfig.include_drivers,
            include_firmware: buildConfig.include_firmware,
            pxe_boot: buildConfig.pxe_boot,
            uefi_only: buildConfig.uefi_only,
          });
          buildProgress.id = result.id;
          // Poll for progress
          buildPollTimer = setInterval(async () => {
            try {
              const b = await api.getBuild(buildProgress.id);
              buildProgress.percent = b.progress || 0;
              buildProgress.message = b.message || '';
              buildProgress.status = b.status;
              if (b.status === 'completed' || b.status === 'failed') {
                clearInterval(buildPollTimer);
                if (b.status === 'completed') {
                  toast.success('Build Complete', 'Media build finished successfully.');
                } else {
                  buildProgress.error = b.error || 'Build failed.';
                  toast.error('Build Failed', buildProgress.error);
                }
              }
            } catch (e) {
              // Ignore poll errors
            }
          }, 2000);
        } catch (e) {
          buildProgress.status = 'failed';
          buildProgress.error = e.message;
          toast.error('Build Failed', e.message);
        }
      }
    }

    const mediaTypes = [
      { id: 'ISO', name: 'ISO Image', icon: 'disc',  desc: 'Create a bootable ISO file for burning to DVD or mounting.' },
      { id: 'USB', name: 'USB Drive', icon: 'usb',   desc: 'Create a bootable USB image (dd-ready raw image).' },
      { id: 'PXE', name: 'PXE Bundle',icon: 'server', desc: 'Generate PXE boot configuration files and menus.' },
    ];

    // === UPDATES ===
    const updLoading = ref(false);
    const updChecking = ref(false);
    const updApplying = ref(null);
    const updData = reactive({
      last_checked: null,
      components: [],
    });

    async function loadUpdates() {
      updLoading.value = true;
      try {
        const data = await fetchOr(() => api.getUpdates(), 'updates');
        Object.assign(updData, data);
      } catch (e) {
        toast.error('Update Error', e.message);
      }
      updLoading.value = false;
    }

    async function checkUpdates() {
      updChecking.value = true;
      try {
        if (useMock) {
          await new Promise(r => setTimeout(r, 1500));
          updData.last_checked = new Date().toISOString();
          toast.success('Check Complete', 'Component versions are up to date.');
        } else {
          const data = await api.checkUpdates();
          Object.assign(updData, data);
          toast.success('Check Complete', 'Version check finished.');
        }
      } catch (e) {
        toast.error('Check Failed', e.message);
      }
      updChecking.value = false;
    }

    async function applyUpdate(comp) {
      updApplying.value = comp.name;
      try {
        if (useMock) {
          await new Promise(r => setTimeout(r, 2000));
          comp.current = comp.latest;
          comp.status = 'up-to-date';
          toast.success('Updated', `${comp.name} updated to ${comp.latest}.`);
        } else {
          await api.applyUpdate(comp.name);
          toast.success('Updated', `${comp.name} updated successfully.`);
          await loadUpdates();
        }
      } catch (e) {
        toast.error('Update Failed', e.message);
      }
      updApplying.value = null;
    }

    const updatesAvailable = computed(() => {
      return updData.components.filter(c => c.status === 'update-available').length;
    });

    // === HISTORY ===
    const histLoading = ref(false);
    const histBuilds = ref([]);

    async function loadHistory() {
      histLoading.value = true;
      try {
        histBuilds.value = await fetchOr(() => api.getBuilds(), 'builds');
      } catch (e) {
        toast.error('History Error', e.message);
      }
      histLoading.value = false;
    }

    function downloadBuild(build) {
      if (useMock) {
        toast.info('Demo Mode', 'Download not available in demo mode.');
        return;
      }
      api.downloadBuild(build.id);
    }

    // === PAGE LOADING ===
    watch(currentRoute, (route) => {
      switch (route) {
        case 'dashboard': loadDashboard(); break;
        case 'images':    loadImages(); loadOsDefinitions(); break;
        case 'build':     loadOsDefinitions(); break;
        case 'updates':   loadUpdates(); break;
        case 'history':   loadHistory(); break;
      }
    }, { immediate: true });

    return {
      // Theme
      darkMode, toggleTheme,
      // Routing
      currentRoute, setRoute, navItems, pageTitle,
      // Sidebar
      sidebarOpen, toggleSidebar, closeSidebar,
      // Toasts
      toasts, removeToast,
      // Icons
      ICONS,
      // Helpers
      formatBytes, formatDate, formatDuration, statusBadgeClass,
      // Dashboard
      dashLoading, dashData, cachePercent, cacheBarColor, loadDashboard,
      // Images
      imgLoading, images, imgDragover, imgUploading, imgUploadProgress,
      imgDeleteConfirm, totalCacheSize,
      loadImages, deleteImage, handleImageDrop, handleImageFileSelect,
      uploadImageFiles, cancelUpload,
      // Build
      buildSteps, buildStep, buildConfig, buildProgress, buildLoading,
      osDefinitions, mediaTypes,
      selectOs, selectMedia, nextBuildStep, prevBuildStep, resetBuild, startBuild,
      // Updates
      updLoading, updChecking, updApplying, updData, updatesAvailable,
      loadUpdates, checkUpdates, applyUpdate,
      // History
      histLoading, histBuilds, downloadBuild, loadHistory,
    };
  },
});

app.mount('#app');
