# App Review Notes

## Demo Server
The build includes a development server profile named `Railway Dev` for review and screenshots.

## Primary Test Flow
1. Open `Explorer`.
2. Browse the included demo tables such as:
   - `chart_doc_sales_daily`
   - `chart_doc_marketing_attribution`
   - `chart_doc_service_latency`
   - `chart_doc_support_satisfaction`
3. Tap rows to view or edit live data.
4. Use the schema button in the Results header to inspect or edit table columns.
5. Open `Studio` to run highlighted SQL manually.
6. Open `Charts` to run saved chart presets from their stored SQL.

## Chart Review Scenarios
- `Sales by Channel`: bar chart
- `Daily Sales Area`: area chart with date axis
- `Conversions by Device`: donut chart
- `Latency Trend`: line chart
- `Error Rate Scatter`: point chart

## iCloud Usage
- Saved server profiles sync through iCloud key-value storage.
- Saved chart presets are stored as YAML and mirrored through iCloud Documents when available.

## Notes
- The app connects to real MySQL and PostgreSQL servers.
- The app supports schema browsing, row editing, chart presets, and schema column editing.
