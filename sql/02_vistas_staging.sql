-- ============================================================
-- TDC Data Warehouse — Vistas de transformación (Staging)
-- Base de datos: TDC_Staging
-- Estrategia: ELT estricto — SSIS carga datos crudos en tablas
-- brutas (todo como NVARCHAR Unicode). Estas vistas contienen
-- toda la lógica de negocio y tipado antes de poblar el DW.
-- ============================================================
-- Orden de dependencias:
--   1. vista_ETL_Geografia
--   2. vista_ETL_Tiempo
--   3. vista_ETL_Productos
--   4. vista_ETL_Empleados
--   5. vista_ETL_Cliente      (depende de DIM_GEOGRAFIA_CLIENTE ya cargada)
--   6. VW_FACT_INVENTARIO
--   7. VW_FACT_VENTAS         (depende de las tablas auxiliares — ver archivo 03)
-- ============================================================

USE TDC_Staging;
GO

-- ------------------------------------------------------------
-- 1. vista_ETL_Geografia
-- Fuente: stg_Geografia (de Regions.txt, delimitado por pipes)
-- Limpia espacios y filtra filas sin código postal.
-- Esta vista es leída por el componente Multicast de SSIS,
-- que duplica el flujo hacia DIM_GEOGRAFIA_VENTA y
-- DIM_GEOGRAFIA_CLIENTE simultáneamente.
-- ------------------------------------------------------------

CREATE VIEW vista_ETL_Geografia AS
SELECT DISTINCT
    CAST(TRIM(col_ciudad)  AS VARCHAR(100)) AS Ciudad,
    CAST(TRIM(col_estado)  AS VARCHAR(100)) AS Estado_Provincia,
    CAST(TRIM(col_cp)      AS VARCHAR(20))  AS Codigo_Postal,
    CAST(TRIM(col_region)  AS VARCHAR(50))  AS Region_Comercial
FROM dbo.stg_Geografia
WHERE col_cp IS NOT NULL;
GO

-- ------------------------------------------------------------
-- 2. vista_ETL_Tiempo
-- Genera el calendario completo mediante CTE recursiva.
-- Nota: requiere OPTION (MAXRECURSION 0) al ejecutarse desde
-- SSIS (configurado en el OLE DB Source del paquete).
-- Cruza con stg_Feriados para marcar días festivos.
-- El ISNUMERIC en el LEFT JOIN filtra la fila de encabezado
-- "DATE" que Excel incluye como texto en la tabla bruta.
-- ------------------------------------------------------------

CREATE VIEW vista_ETL_Tiempo AS
WITH CTE_Calendario AS (
    SELECT CAST('2002-01-01' AS DATE) AS FechaReal
    UNION ALL
    SELECT DATEADD(DAY, 1, FechaReal)
    FROM CTE_Calendario
    WHERE FechaReal < '2009-12-31'
)
SELECT
    CAST(CONVERT(VARCHAR(8), c.FechaReal, 112) AS INT)  AS SK_Tiempo,
    c.FechaReal                                          AS Fecha,
    DATEPART(YEAR,    c.FechaReal)                       AS Año,
    DATEPART(QUARTER, c.FechaReal)                       AS Trimestre,
    DATEPART(MONTH,   c.FechaReal)                       AS Mes,
    CAST(DATENAME(MONTH,   c.FechaReal) AS VARCHAR(20))  AS Nombre_Mes,
    DATEPART(DAY,     c.FechaReal)                       AS Dia,
    CAST(DATENAME(WEEKDAY, c.FechaReal) AS VARCHAR(20))  AS Dia_Semana,
    CAST(CASE
        WHEN f.nombre_feriado IS NOT NULL THEN 1
        ELSE 0
    END AS BIT)                                          AS Es_Feriado,
    CAST(CASE
        WHEN DATEPART(WEEKDAY, c.FechaReal) IN (1, 7) THEN 1
        ELSE 0
    END AS BIT)                                          AS Es_Fin_De_Semana
FROM CTE_Calendario c
LEFT JOIN stg_Feriados f
    ON (CASE
            WHEN ISNUMERIC(f.fecha) = 1
            THEN DATEADD(DAY, CAST(CAST(f.fecha AS FLOAT) AS INT), '1899-12-30')
            ELSE NULL
        END) = c.FechaReal;
GO

-- ------------------------------------------------------------
-- 3. vista_ETL_Productos
-- Fuente: stg_Productos (de Products.txt)
-- Deriva Rubro, Presentacion, Tipo_Envase, Es_Diet y
-- Capacidad_Litros mediante CASE WHEN sobre los campos
-- DETAIL y PACKAGE del archivo fuente.
-- ------------------------------------------------------------

CREATE VIEW vista_ETL_Productos AS
SELECT
    CAST(TRIM(PRODUCT_ID) AS VARCHAR(50))   AS Product_ID,
    CAST(TRIM(DETAIL)     AS VARCHAR(150))  AS Detalle_Producto,
    CAST(
        CASE
            WHEN DETAIL LIKE '%Cola%'                                           THEN 'Cola'
            WHEN DETAIL LIKE '%Beer%'    OR DETAIL LIKE '%Cerveza%'             THEN 'Beer'
            WHEN DETAIL LIKE '%Soda%'    OR DETAIL LIKE '%Gaseosa%'             THEN 'Soda'
            WHEN DETAIL LIKE '%Juice%'   OR DETAIL LIKE '%Jugo%'                THEN 'Juices'
            WHEN DETAIL LIKE '%Energy%'  OR DETAIL LIKE '%Monster%'
              OR DETAIL LIKE '%Red Bull%'                                        THEN 'Energy Drinks'
            ELSE 'Otros'
        END
    AS VARCHAR(50))                         AS Rubro,
    CAST(
        CASE
            WHEN PACKAGE LIKE '%1%L%'                                           THEN 'Botella 1L'
            WHEN PACKAGE LIKE '%2%L%'                                           THEN 'Botella 2L'
            WHEN PACKAGE LIKE '%670%cm3%' OR PACKAGE LIKE '%670%cc%'           THEN 'Botella 670cm3'
            WHEN PACKAGE LIKE '%330%cm3%' OR PACKAGE LIKE '%330%cc%'           THEN 'Lata 330cm3'
            WHEN PACKAGE LIKE '%500%cm3%' OR PACKAGE LIKE '%500%cc%'           THEN 'Lata 500cm3'
            ELSE TRIM(PACKAGE)
        END
    AS VARCHAR(50))                         AS Presentacion,
    CAST(
        CASE
            WHEN PACKAGE LIKE '%Bottle%' OR PACKAGE LIKE '%Botella%'
              OR PACKAGE LIKE '%L%'      OR PACKAGE LIKE '%670%'               THEN 'Botella'
            WHEN PACKAGE LIKE '%Can%'    OR PACKAGE LIKE '%Lata%'
              OR PACKAGE LIKE '%330%'    OR PACKAGE LIKE '%500%'               THEN 'Lata'
            ELSE 'No Especificado'
        END
    AS VARCHAR(50))                         AS Tipo_Envase,
    CASE
        WHEN DETAIL LIKE '%Diet%' OR DETAIL LIKE '%Zero%' OR DETAIL LIKE '%Light%'
        THEN 1 ELSE 0
    END                                     AS Es_Diet,
    CAST(
        CASE
            WHEN PACKAGE LIKE '%1%L%'                                           THEN 1.000
            WHEN PACKAGE LIKE '%2%L%'                                           THEN 2.000
            WHEN PACKAGE LIKE '%670%cm3%' OR PACKAGE LIKE '%670%cc%'           THEN 0.670
            WHEN PACKAGE LIKE '%330%cm3%' OR PACKAGE LIKE '%330%cc%'           THEN 0.330
            WHEN PACKAGE LIKE '%500%cm3%' OR PACKAGE LIKE '%500%cc%'           THEN 0.500
            ELSE 0.000
        END
    AS DECIMAL(10,3))                       AS Capacidad_Litros
FROM stg_Productos
WHERE PRODUCT_ID IS NOT NULL AND TRIM(PRODUCT_ID) <> '';
GO

-- ------------------------------------------------------------
-- 4. vista_ETL_Empleados
-- Fuente: stg_Empleados (de Employee.xls)
-- TRY_CONVERT en fechas para manejar valores nulos o malformados.
-- ------------------------------------------------------------

CREATE VIEW vista_ETL_Empleados AS
SELECT
    CAST(TRIM(EMPLOYEE_ID)     AS VARCHAR(50))  AS Employee_ID,
    CAST(TRIM(FULL_NAME)       AS VARCHAR(150)) AS Nombre_Completo,
    CAST(UPPER(LEFT(TRIM(GENDER), 1)) AS CHAR(1))  AS Genero,
    CAST(TRIM(CATEGORY)        AS VARCHAR(50))  AS Categoria,
    TRY_CONVERT(DATE, TRIM(EMPLOYMENT_DATE), 101)  AS Fecha_Contratacion,
    TRY_CONVERT(DATE, TRIM(BIRTH_DATE),      101)  AS Fecha_Nacimiento,
    CAST(TRIM(EDUCATION_LEVEL) AS VARCHAR(50))  AS Nivel_Educativo
FROM stg_Empleados
WHERE EMPLOYEE_ID IS NOT NULL AND TRIM(EMPLOYEE_ID) <> '';
GO

-- ------------------------------------------------------------
-- 5. vista_ETL_Cliente
-- Fuentes: stg_Clientes_Minoristas (customer_R.xml)
--          stg_Clientes_Mayoristas (customer_W.xml)
-- Unifica ambas fuentes via UNION ALL, etiquetando Tipo_Cliente.
-- Resuelve FK_Geo_Cliente via LEFT JOIN contra DIM_GEOGRAFIA_CLIENTE
-- (ya cargada), usando LOWER() para match case-insensitive.
-- Clientes sin match geográfico quedan con FK_Geo_Cliente = -1
-- (fila comodín insertada previamente en la dimensión).
-- ------------------------------------------------------------

CREATE VIEW vista_ETL_Cliente AS
WITH Clientes_Unificados AS (
    SELECT
        CAST(TRIM(Customer_ID)       AS VARCHAR(50))  AS Customer_ID,
        CAST(TRIM(Full_Name)         AS VARCHAR(150)) AS Nombre_Completo,
        TRY_CAST(TRIM(Fecha_Nacimiento) AS DATE)      AS Fecha_Nacimiento,
        CAST('Minorista'             AS VARCHAR(20))  AS Tipo_Cliente,
        TRIM(Ciudad)                                  AS Ciudad,
        TRIM(Estado_Provincia)                        AS Estado_Provincia,
        TRIM(Codigo_Postal)                           AS Codigo_Postal
    FROM stg_Clientes_Minoristas
    UNION ALL
    SELECT
        CAST(TRIM(Customer_ID)       AS VARCHAR(50))  AS Customer_ID,
        CAST(TRIM(Razon_Social)      AS VARCHAR(150)) AS Nombre_Completo,
        CAST(NULL AS DATE)                            AS Fecha_Nacimiento,
        CAST('Mayorista'             AS VARCHAR(20))  AS Tipo_Cliente,
        TRIM(Ciudad)                                  AS Ciudad,
        TRIM(Estado_Provincia)                        AS Estado_Provincia,
        TRIM(Codigo_Postal)                           AS Codigo_Postal
    FROM stg_Clientes_Mayoristas
)
SELECT
    c.Customer_ID,
    c.Nombre_Completo,
    c.Fecha_Nacimiento,
    c.Tipo_Cliente,
    ISNULL(g.SK_Geo_Cliente, -1) AS FK_Geo_Cliente
FROM Clientes_Unificados c
LEFT JOIN TDC_DataWarehouse.dbo.DIM_GEOGRAFIA_CLIENTE g
    ON LOWER(c.Ciudad)            = LOWER(g.Ciudad)
    AND LOWER(c.Estado_Provincia) = LOWER(g.Estado_Provincia);
GO

-- ------------------------------------------------------------
-- 6. VW_FACT_INVENTARIO
-- Fuente: stg_Stock (de Stock.txt)
-- LEFT(Fecha, 10) descarta la hora y el formato AM/PM con puntos
-- que SQL Server no puede parsear directamente.
-- INNER JOIN contra DIM_PRODUCTO: descarta filas sin match
-- (producto no registrado en el catálogo).
-- ------------------------------------------------------------

CREATE VIEW VW_FACT_INVENTARIO AS
SELECT
    CAST(FORMAT(CONVERT(DATE, LEFT(s.Fecha, 10), 101), 'yyyyMMdd') AS INT) AS FK_Tiempo,
    dp.SK_Producto                                                          AS FK_Producto,
    CAST(s.Variation AS INT)                                                AS Cantidad_Stock
FROM STG_STOCK_BRUTO s
INNER JOIN TDC_DataWarehouse.dbo.DIM_PRODUCTO dp
    ON s.Product_ID = dp.Product_ID;
GO

-- ------------------------------------------------------------
-- 7. VW_FACT_VENTAS
-- Ensambla las 3 tablas auxiliares de Staging (ver archivo 03)
-- con las dimensiones del DW para producir la tabla de hechos.
--
-- FK_Geo_Venta se resuelve encadenando:
--   Venta → DIM_CLIENTE → DIM_GEOGRAFIA_CLIENTE → DIM_GEOGRAFIA_VENTA
-- ya que la fuente no provee un maestro de sucursales que permita
-- resolver la geografía directamente desde la transacción.
--
-- Los campos Monto_Bruto, Monto_Descuento y Monto_Neto_Ventas
-- representan el monto de la FACTURA COMPLETA replicado en cada
-- línea, dado que el descuento de negocio aplica a nivel de
-- factura (no por producto individual).
-- ------------------------------------------------------------

CREATE VIEW VW_FACT_VENTAS AS
SELECT
    CAST(FORMAT(CAST(CONVERT(DATE, v.Fecha, 120) AS DATE), 'yyyyMMdd') AS INT) AS FK_Tiempo,
    dp.SK_Producto                                      AS FK_Producto,
    ISNULL(dc.SK_Cliente,  -1)                         AS FK_Cliente,
    ISNULL(de.SK_Empleado, -1)                         AS FK_Empleado,
    ISNULL(gv.SK_Geo_Venta, -1)                        AS FK_Geo_Venta,
    v.Billing_ID                                        AS Nro_Factura,
    v.Cantidad                                          AS Cantidad_Unidades,
    ROUND(v.Cantidad * dp.Capacidad_Litros, 3)         AS Cantidad_Litros,
    v.Precio_Unitario,
    mf.Monto_Bruto_Factura                             AS Monto_Bruto,
    ROUND(
        mf.Monto_Bruto_Factura * ISNULL(md.Mejor_Porcentaje, 0) / 100
    , 2)                                               AS Monto_Descuento,
    ROUND(
        mf.Monto_Bruto_Factura -
        (mf.Monto_Bruto_Factura * ISNULL(md.Mejor_Porcentaje, 0) / 100)
    , 2)                                               AS Monto_Neto_Ventas
FROM STG_VENTAS_CON_PRECIO v
INNER JOIN STG_MONTO_FACTURA mf
    ON v.Billing_ID = mf.Billing_ID
LEFT JOIN STG_MEJOR_DESCUENTO md
    ON v.Billing_ID = md.Billing_ID
INNER JOIN TDC_DataWarehouse.dbo.DIM_PRODUCTO dp
    ON v.Product_ID = dp.Product_ID
LEFT JOIN TDC_DataWarehouse.dbo.DIM_CLIENTE dc
    ON v.Customer_ID = dc.Customer_ID
LEFT JOIN TDC_DataWarehouse.dbo.DIM_EMPLEADO de
    ON v.Employee_ID = de.Employee_ID
LEFT JOIN TDC_DataWarehouse.dbo.DIM_GEOGRAFIA_CLIENTE gc
    ON dc.FK_Geo_Cliente = gc.SK_Geo_Cliente
LEFT JOIN TDC_DataWarehouse.dbo.DIM_GEOGRAFIA_VENTA gv
    ON gc.Ciudad            = gv.Ciudad
    AND gc.Estado_Provincia = gv.Estado_Provincia
    AND gc.Codigo_Postal    = gv.Codigo_Postal;
GO
