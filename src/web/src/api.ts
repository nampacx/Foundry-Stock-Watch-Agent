export type Sentiment = 'bullish' | 'neutral' | 'bearish' | 'none' | 'failed'

export interface Report {
  ticker: string
  name: string
  exchange: string | null
  runUtc: string
  windowStartUtc: string
  sentiment: Sentiment
  failed: boolean
  markdown: string
}

export interface CompanySummary {
  ticker: string
  name: string
  exchange: string | null
  latest: Report | null
}

async function get<T>(path: string): Promise<T> {
  const res = await fetch(path, { headers: { Accept: 'application/json' } })
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}`)
  return res.json() as Promise<T>
}

export const getCompanies = () => get<CompanySummary[]>('/api/companies')

export const getReports = (ticker: string) =>
  get<Report[]>(`/api/companies/${encodeURIComponent(ticker)}/reports?limit=30`)
