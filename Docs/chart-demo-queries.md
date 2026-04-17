# Chart Demo Dataset

The Railway dev database now includes `railway.chart_doc_shipments` with 50 deterministic rows for visualizer documentation and manual testing.

## Columns

- `shipment_code`
- `category`
- `route_label`
- `delivered_at`
- `package_count`
- `distance_km`
- `delivery_hours`
- `region`

## Suggested Visualizations

### Bar chart

Category X axis with labels:

```sql
SELECT
  category,
  SUM(package_count) AS total_packages
FROM chart_doc_shipments
GROUP BY category
ORDER BY total_packages DESC, category ASC;
```

Suggested mapping:

- Chart: `Bar`
- X axis: `category`
- Y axis: `total_packages`
- Labels: `category`

### Area chart

Date X axis:

```sql
SELECT
  DATE(delivered_at) AS delivered_day,
  SUM(package_count) AS total_packages
FROM chart_doc_shipments
GROUP BY DATE(delivered_at)
ORDER BY delivered_day ASC;
```

Suggested mapping:

- Chart: `Area`
- X axis: `delivered_day`
- X mode: `Date`
- Y axis: `total_packages`
- Labels: `delivered_day`

### Pie / donut chart

```sql
SELECT
  region,
  SUM(package_count) AS total_packages
FROM chart_doc_shipments
GROUP BY region
ORDER BY total_packages DESC, region ASC;
```

Suggested mapping:

- Chart: `Pie` or `Donut`
- X axis: `region`
- Y axis: `total_packages`
- Labels: `region`

### Line chart

Average delivery time in hours by distance:

```sql
SELECT
  distance_km,
  ROUND(AVG(delivery_hours), 2) AS avg_delivery_hours
FROM chart_doc_shipments
GROUP BY distance_km
ORDER BY distance_km ASC;
```

Suggested mapping:

- Chart: `Line`
- X axis: `distance_km`
- X mode: `Number`
- Y axis: `avg_delivery_hours`
- Labels: `distance_km`
