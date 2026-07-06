-- ============================================================
-- TDC Data Warehouse — Creación del esquema dimensional
-- Base de datos: TDC_DataWarehouse
-- Modelo: Esquema en estrella con outrigger en DIM_CLIENTE
-- ============================================================

USE TDC_DataWarehouse;
GO

-- ------------------------------------------------------------
-- DIMENSIONES GEOGRÁFICAS
-- Dos tablas independientes para evitar relaciones ambiguas
-- en Power BI (outrigger + dimensión directa de la fact)
-- ------------------------------------------------------------

CREATE TABLE DIM_GEOGRAFIA_CLIENTE (
    SK_Geo_Cliente    INT          IDENTITY(1,1) NOT NULL,
    Ciudad            VARCHAR(100) NOT NULL,
    Estado_Provincia  VARCHAR(100) NOT NULL,
    Codigo_Postal     VARCHAR(20)  NOT NULL,
    Region_Comercial  VARCHAR(50)  NOT NULL,  -- East, West, Central, South
    CONSTRAINT PK_DIM_GEOGRAFIA_CLIENTE PRIMARY KEY CLUSTERED (SK_Geo_Cliente)
);

CREATE TABLE DIM_GEOGRAFIA_VENTA (
    SK_Geo_Venta      INT          IDENTITY(1,1) NOT NULL,
    Ciudad            VARCHAR(100) NOT NULL,
    Estado_Provincia  VARCHAR(100) NOT NULL,
    Codigo_Postal     VARCHAR(20)  NOT NULL,
    Region_Comercial  VARCHAR(50)  NOT NULL,  -- East, West, Central, South
    CONSTRAINT PK_DIM_GEOGRAFIA_VENTA PRIMARY KEY CLUSTERED (SK_Geo_Venta)
);

-- ------------------------------------------------------------
-- DIM_CLIENTE
-- Outrigger: referencia a DIM_GEOGRAFIA_CLIENTE via FK_Geo_Cliente
-- Fuentes: customer_R.xml (minoristas) + customer_W.xml (mayoristas)
-- ------------------------------------------------------------

CREATE TABLE DIM_CLIENTE (
    SK_Cliente       INT          IDENTITY(1,1) NOT NULL,
    Customer_ID      VARCHAR(50)  NOT NULL,  -- Business Key de los archivos XML
    Nombre_Completo  VARCHAR(150) NOT NULL,
    Fecha_Nacimiento DATE         NULL,
    Tipo_Cliente     VARCHAR(20)  NOT NULL,  -- Minorista / Mayorista
    FK_Geo_Cliente   INT          NOT NULL,
    CONSTRAINT PK_DIM_CLIENTE PRIMARY KEY CLUSTERED (SK_Cliente),
    CONSTRAINT FK_DIM_CLIENTE_DIM_GEOGRAFIA_CLIENTE
        FOREIGN KEY (FK_Geo_Cliente)
        REFERENCES DIM_GEOGRAFIA_CLIENTE (SK_Geo_Cliente)
);

-- ------------------------------------------------------------
-- DIM_PRODUCTO
-- Fuente: Products.txt
-- Atributos derivados por lógica CASE WHEN en Staging
-- ------------------------------------------------------------

CREATE TABLE DIM_PRODUCTO (
    SK_Producto       INT            IDENTITY(1,1) NOT NULL,
    Product_ID        VARCHAR(50)    NOT NULL,       -- Business Key de Products.txt
    Detalle_Producto  VARCHAR(150)   NOT NULL,
    Rubro             VARCHAR(50)    NOT NULL,        -- Cola, Beer, Soda, Juices, Energy Drinks
    Presentacion      VARCHAR(50)    NOT NULL,        -- Botella 1L, Lata 330cm3, etc.
    Tipo_Envase       VARCHAR(50)    NOT NULL,        -- Botella / Lata
    Es_Diet           BIT            NOT NULL,        -- 1 = Sí, 0 = No
    Capacidad_Litros  DECIMAL(10,3)  NOT NULL,
    CONSTRAINT PK_DIM_PRODUCTO PRIMARY KEY CLUSTERED (SK_Producto)
);

-- ------------------------------------------------------------
-- DIM_EMPLEADO
-- Fuente: Employee.xls
-- ------------------------------------------------------------

CREATE TABLE DIM_EMPLEADO (
    SK_Empleado        INT         IDENTITY(1,1) NOT NULL,
    Employee_ID        VARCHAR(50) NOT NULL,  -- Business Key de Employee.xls
    Nombre_Completo    VARCHAR(150) NOT NULL,
    Genero             CHAR(1)     NULL,
    Categoria          VARCHAR(50) NULL,
    Fecha_Contratacion DATE        NULL,
    Fecha_Nacimiento   DATE        NULL,
    Nivel_Educativo    VARCHAR(50) NULL,
    CONSTRAINT PK_DIM_EMPLEADO PRIMARY KEY CLUSTERED (SK_Empleado)
);

-- ------------------------------------------------------------
-- DIM_TIEMPO
-- Dimensión conformada: sirve a FACT_VENTAS y FACT_INVENTARIO
-- SK_Tiempo: clave inteligente formato AAAAMMDD (ej: 20090125)
-- Generada mediante CTE recursiva en Staging
-- ------------------------------------------------------------

CREATE TABLE DIM_TIEMPO (
    SK_Tiempo        INT         NOT NULL,  -- Formato AAAAMMDD
    Fecha            DATE        NOT NULL,
    Año              INT         NOT NULL,
    Trimestre        INT         NOT NULL,
    Mes              INT         NOT NULL,
    Nombre_Mes       VARCHAR(20) NOT NULL,
    Dia              INT         NOT NULL,
    Dia_Semana       VARCHAR(20) NOT NULL,
    Es_Feriado       BIT         NOT NULL,  -- Cruzado con Holidays.xls en el ETL
    Es_Fin_De_Semana BIT         NOT NULL,
    CONSTRAINT PK_DIM_TIEMPO PRIMARY KEY CLUSTERED (SK_Tiempo)
);
GO

-- ------------------------------------------------------------
-- FACT_VENTAS
-- Granularidad: una línea de producto por factura
-- ~1.6M filas — cubre Feb 2006 a Ago 2009
-- Nota: Monto_Bruto, Monto_Descuento y Monto_Neto_Ventas
-- representan el monto de la FACTURA COMPLETA replicado en
-- cada línea, ya que el descuento aplica a nivel de factura.
-- ------------------------------------------------------------

CREATE TABLE FACT_VENTAS (
    SK_Ventas         INT            IDENTITY(1,1) NOT NULL,
    FK_Tiempo         INT            NOT NULL,
    FK_Producto       INT            NOT NULL,
    FK_Cliente        INT            NOT NULL,
    FK_Empleado       INT            NOT NULL,
    FK_Geo_Venta      INT            NOT NULL,  -- Geografía de la transacción
    Nro_Factura       VARCHAR(50)    NOT NULL,  -- Dimensión degradada (Billing_ID)

    -- Métricas a nivel de línea de producto
    Cantidad_Unidades INT            NOT NULL,
    Cantidad_Litros   DECIMAL(12,3)  NOT NULL,  -- Unidades * Capacidad_Litros
    Precio_Unitario   DECIMAL(12,2)  NOT NULL,  -- Precio vigente al momento de la venta

    -- Métricas a nivel de factura completa (replicadas por línea)
    Monto_Bruto       DECIMAL(12,2)  NOT NULL,  -- Total factura sin descuento
    Monto_Descuento   DECIMAL(12,2)  NOT NULL,  -- Mejor descuento aplicable
    Monto_Neto_Ventas DECIMAL(12,2)  NOT NULL,  -- Monto_Bruto - Monto_Descuento

    CONSTRAINT PK_FACT_VENTAS PRIMARY KEY CLUSTERED (SK_Ventas),
    CONSTRAINT FK_FACT_VENTAS_DIM_TIEMPO
        FOREIGN KEY (FK_Tiempo)     REFERENCES DIM_TIEMPO (SK_Tiempo),
    CONSTRAINT FK_FACT_VENTAS_DIM_PRODUCTO
        FOREIGN KEY (FK_Producto)   REFERENCES DIM_PRODUCTO (SK_Producto),
    CONSTRAINT FK_FACT_VENTAS_DIM_CLIENTE
        FOREIGN KEY (FK_Cliente)    REFERENCES DIM_CLIENTE (SK_Cliente),
    CONSTRAINT FK_FACT_VENTAS_DIM_EMPLEADO
        FOREIGN KEY (FK_Empleado)   REFERENCES DIM_EMPLEADO (SK_Empleado),
    CONSTRAINT FK_FACT_VENTAS_DIM_GEOGRAFIA_VENTA
        FOREIGN KEY (FK_Geo_Venta)  REFERENCES DIM_GEOGRAFIA_VENTA (SK_Geo_Venta)
);

-- ------------------------------------------------------------
-- FACT_INVENTARIO
-- Granularidad: foto diaria de stock por producto
-- 993 filas — cubre Ene 2002 a Dic 2004 (fuente: Stock.txt)
-- ------------------------------------------------------------

CREATE TABLE FACT_INVENTARIO (
    SK_Inventario  INT  IDENTITY(1,1) NOT NULL,
    FK_Tiempo      INT  NOT NULL,
    FK_Producto    INT  NOT NULL,
    Cantidad_Stock INT  NOT NULL,  -- Foto del stock al cierre del día
    CONSTRAINT PK_FACT_INVENTARIO PRIMARY KEY CLUSTERED (SK_Inventario),
    CONSTRAINT FK_FACT_INVENTARIO_DIM_TIEMPO
        FOREIGN KEY (FK_Tiempo)   REFERENCES DIM_TIEMPO (SK_Tiempo),
    CONSTRAINT FK_FACT_INVENTARIO_DIM_PRODUCTO
        FOREIGN KEY (FK_Producto) REFERENCES DIM_PRODUCTO (SK_Producto)
);
GO
