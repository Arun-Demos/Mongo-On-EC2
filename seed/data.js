// Initial dataset for the "services" collection
const db = connect("localhost:27017/stardb");

db.services.insertMany([
  { name: "StarVision",    subscribers: NumberInt(12000), revenue: NumberDecimal("48000.00") },
  { name: "StarDocs",      subscribers: NumberInt(8500),  revenue: NumberDecimal("25500.00") },
  { name: "StarCloud",     subscribers: NumberInt(15000), revenue: NumberDecimal("112000.00") },
  { name: "StarAI Engine", subscribers: NumberInt(6300),  revenue: NumberDecimal("75500.00") }
]);
