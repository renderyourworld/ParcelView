-- +goose Up
CREATE TABLE layer_types (
    id smallint PRIMARY KEY,
    name varchar(50) UNIQUE NOT NULL
);

INSERT INTO layer_types (id, name) VALUES
    (1, 'parcels'),
    (2, 'counties'),
    (3, 'tax_heatmap_2015'),
    (4, 'tax_heatmap_2016'),
    (5, 'tax_heatmap_2017'),
    (6, 'tax_heatmap_2018'),
    (7, 'tax_heatmap_2019'),
    (8, 'tax_heatmap_2020'),
    (9, 'tax_heatmap_2021'),
    (10, 'tax_heatmap_2022'),
    (11, 'tax_heatmap_2023'),
    (12, 'tax_heatmap_2024');

-- +goose Down
DROP TABLE layer_types;