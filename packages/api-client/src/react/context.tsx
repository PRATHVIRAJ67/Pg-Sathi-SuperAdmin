import { createContext, useContext, type ReactNode } from 'react';
import type { AdminService, DataService } from '../service';
import type { AuthAdapter, FileStorage } from '../transport';

export type BackendMode = 'supabase' | 'demo' | 'demo-snapshot';

export interface DemoControls {
  /** Human-readable explanation shown in the demo banner. */
  description: string;
  /** Wipes demo data in this browser/device and re-creates the sample workspace. */
  reset?: () => Promise<void>;
  /** Pre-filled sign-in for the sample owner account. */
  sampleAccount?: { email: string; password: string };
  readOnly?: boolean;
}

export interface Backend {
  mode: BackendMode;
  data: DataService;
  admin: AdminService;
  auth: AuthAdapter;
  storage: FileStorage;
  demo?: DemoControls;
}

const BackendContext = createContext<Backend | null>(null);

export function BackendProvider({ backend, children }: { backend: Backend; children: ReactNode }) {
  return <BackendContext.Provider value={backend}>{children}</BackendContext.Provider>;
}

export function useBackend(): Backend {
  const value = useContext(BackendContext);
  if (!value) throw new Error('useBackend must be used inside <BackendProvider>');
  return value;
}

export const unavailableStorage: FileStorage = {
  available: false,
  async upload() {
    throw new Error('File uploads need Supabase Storage. They are not available in demo mode.');
  },
  async signedUrl() {
    throw new Error('File uploads need Supabase Storage. They are not available in demo mode.');
  },
  async remove() {
    throw new Error('File uploads need Supabase Storage. They are not available in demo mode.');
  },
};
