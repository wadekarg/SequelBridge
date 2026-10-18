SELECT c.full_name, r.name AS region, COUNT(o.id) AS orders, SUM(i.qty) AS items
FROM crm.customers c
JOIN shop.orders o ON o.customer_id = c.id
JOIN shop.order_items i ON i.order_id = o.id
JOIN ref.regions r ON r.code = c.region_code
GROUP BY c.full_name, r.name
ORDER BY orders DESC
LIMIT 200
