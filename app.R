library(shiny)
library(openxlsx)
library(DT)
library(tidyverse)
library(DBI)
library(readxl)


downloadButton <- function(...) {
  tag <- shiny::downloadButton(...)
  tag$attribs$download <- NULL
  tag
}


con <- DBI::dbConnect(odbc::odbc(), Driver = "{SQL Server}", 
                      Server = "MISCPrdAdhocDB", Database = "PRIME", Port = 1433, 
                      Trusted_Connection = T)

mhs_poh_tbl = tbl(con, 'vw_MHS_POH_ENHANCED_3YEAR_ROLLING')

column_reorder_order = function(tbl_name) {
  sql_script = paste('select top 10* from', tbl_name)
  rs <- dbSendQuery(con, sql_script)
  temp = dbColumnInfo(rs) %>% as_tibble()
  reorder_col = temp %>% arrange(desc(type)) %>% pull(name)
  order_col = temp %>% pull(name)
  dbClearResult(rs)
  return(list(reorder_col, order_col))
  
}

poh_col_order = column_reorder_order('vw_MHS_POH_ENHANCED_3YEAR_ROLLING')
poh_col_order[[2]]
poh_col_order[[1]][c(117,119,120, 121)] = c('Proposed Price', 'C Rate MFG', 
                                            'XREF ITEM DESCRIPTION'
                                            ,'XREF PART NUMBER')
poh_col_order[[1]] = poh_col_order[[1]][-136]
poh_col_order[[2]][c(131,133,134, 135)] = c('Proposed Price', 'C Rate MFG', 
                                            'XREF ITEM DESCRIPTION'
                                            ,'XREF PART NUMBER')
poh_col_order[[2]] = poh_col_order[[2]][-136]


shinyApp(
  ui = tagList(
    navbarPage(
      theme = "spacelab",
      
      "FIA Helper",
      tabPanel(
        "Contract File Upload",
        sidebarPanel(
          fileInput(
            "file",
            "Choose CSV/XLS/XLSX File",
            multiple = F,
            accept = c(
              'text/csv',
              'text/comma-separated-values, text/plain',
              '.csv',
              '.xls',
              '.xlsx'
            )
          ),
          numericInput(
            "skip_row",
            "Skip Rows:",
            value = 0,
            min = 0,
            max = 40
          ),
          
          actionButton("action_import", "Import", class = 'btn-primary'),
          selectInput('catalog_col', 'XREF PART NUMBER: ', choices = NULL),
          selectInput('description_col', 'XREF ITEM DESCRIPTION: ', choices = NULL),
          selectInput('uom_col', 'UOM: ', choices = NULL),
          selectInput('c_rate_col', 'C Rate MFG: ', choices = NULL),
          selectInput('price_col', 'Proposed Price: ', choices = NULL),
          radioButtons(
            'tick_choice',
            'Do Catalog Numbers start with tick?',
            choices = c('Yes', 'No'),
            selected = 'No',
            inline = T
          ),
          radioButtons(
            'character_choice',
            'Do you want to have catalog numbers
                              without special characters additionally?',
            choices = c('Yes', 'No'),
            selected = 'No',
            inline = T
          ),
          actionButton('action_final', 'Finalize', class = 'btn-primary')
          
        ),
        mainPanel(tabsetPanel(
          tabPanel("Raw Contract", DTOutput("raw_contract")),
          tabPanel("Clean Contract", DTOutput('clean_contract'))
          #tabPanel("Tab 3", "This panel is intentionally left blank")
        ))
      ),
      tabPanel(
        "PO Data Collection",
        sidebarPanel(
          dateRangeInput(inputId = 'date', label = 'Date Range'),
          actionButton('action_po_collect', 'Raw PO Collection', class = 'btn-primary'),
          uiOutput('location_selector'),
          actionButton('refine_data', 'Refine Data', class = 'btn-primary'),
          downloadButton("downloadData", "Download FIA Raw")
        ),
        mainPanel(tabsetPanel(
          tabPanel('Raw PO Data', DTOutput('raw_po')),
          tabPanel(
            'Item Level Comparison',
            DTOutput("data_table"),
            p("Note: Edit 'Conversion Factor' or toggle 'Included?' as needed.")
          )
        ))
      ),
      tabPanel("Navbar 3", "This panel is intentionally left blank")
    )
  ),
  server = function(input, output) {
    raw_contract <- eventReactive(input$action_import, {
      # Ensure required inputs are provided
      req(input$file, input$skip_row)
      
      # Extract and isolate inputs
      uploaded_file <- isolate(input$file)
      skip_row <- isolate(input$skip_row)
      file_ext <- tools::file_ext(uploaded_file$name)
      
      # Validate the skip_row input
      validate(need(
        is.numeric(skip_row),
        "The 'skip_row' value must be numeric."
      ))
      
      # Read file based on extension
      tryCatch({
        switch(
          file_ext,
          csv = read_csv(uploaded_file$datapath, skip = skip_row),
          xls = read_tsv(uploaded_file$datapath, skip = skip_row),
          xlsx = read_excel(uploaded_file$datapath, skip = skip_row),
          stop(
            "Unsupported file type: Please upload a .csv, .xls, or .xlsx file."
          )
        )
      }, error = function(e) {
        showNotification(paste("Error reading file:", e$message), type = "error")
        NULL  # Return NULL in case of failure
      })
    })
    
    observeEvent(raw_contract(), {
      choices <- colnames(raw_contract())
      updateSelectInput(inputId = 'catalog_col', choices = choices)
    })
    observeEvent(raw_contract(), {
      choices <- colnames(raw_contract())
      updateSelectInput(inputId = 'price_col', choices = choices)
    })
    observeEvent(raw_contract(), {
      choices <- colnames(raw_contract())
      updateSelectInput(inputId = 'c_rate_col', choices = choices)
    })
    observeEvent(raw_contract(), {
      choices <- colnames(raw_contract())
      updateSelectInput(inputId = 'uom_col', choices = choices)
    })
    observeEvent(raw_contract(), {
      choices <- colnames(raw_contract())
      updateSelectInput(inputId = 'description_col', choices = choices)
    })
    
    contract_res <- eventReactive(input$action_final, {
      req(
        raw_contract(),
        input$price_col,
        input$uom_col,
        input$c_rate_col,
        input$description_col,
        input$catalog_col,
        input$tick_choice,
        input$character_choice
      )
      
      # Initial transformation
      temp <- raw_contract() %>%
        rename(
          `Proposed Price` = input$price_col,
          UOM = input$uom_col,
          `C Rate MFG` = input$c_rate_col,
          `XREF ITEM DESCRIPTION` = input$description_col,
          `XREF PART NUMBER` = input$catalog_col
        ) %>%
        select(`Proposed Price`,
               UOM,
               `C Rate MFG`,
               `XREF ITEM DESCRIPTION`,
               `XREF PART NUMBER`)
      
      if (input$tick_choice == "Yes") {
        if (input$character_choice == "Yes") {
          bind_rows(
            temp %>%
              mutate(`XREF PART NUMBER` = substr(
                `XREF PART NUMBER`, 2, nchar(`XREF PART NUMBER`)
              )),
            temp %>%
              mutate(
                `XREF PART NUMBER` = substr(`XREF PART NUMBER`, 2, nchar(`XREF PART NUMBER`)) %>%
                  gsub("[^[:alnum:]]", "", .)
              )
          ) %>%
            unique()
        } else {
          temp %>%
            mutate(`XREF PART NUMBER` = substr(`XREF PART NUMBER`, 2, nchar(`XREF PART NUMBER`)))
        }
      } else {
        if (input$character_choice == "Yes") {
          bind_rows(temp, temp %>%
                      mutate(
                        `XREF PART NUMBER` = gsub("[^[:alnum:]]", "", `XREF PART NUMBER`)
                      )) %>%
            unique()
        } else {
          temp
        }
      }
    })
    
    
    
    output$raw_contract <- renderDataTable({
      raw_contract()
    })
    output$clean_contract <- renderDataTable({
      contract_res()
    })
    po_raw <- eventReactive(input$action_po_collect, {
      req(input$date)
      start_date = isolate(as.character(input$date[[1]]))
      end_date = isolate(as.character(input$date[[2]]))
      
      # material = contract_res() %>% pull(`XREF PART NUMBER`)
      # mhs_poh_tbl %>%
      #   filter(CREATE_DATE >= start_date, CREATE_DATE <= end_date) %>%
      #   filter(
      #     MATERIAL_NUM %in% material | VENDOR_MATERIAL_NUM %in% material |
      #       MANUFACTURER_PART_NUM %in% material |
      #       PREMIER_MANUFACTURER_CATALOG_NUMBER %in% material
      #   ) %>%
      #   select(all_of(poh_col_order[[1]])) %>%
      #   collect() %>%
      #   select(all_of(poh_col_order[[2]])) %>%
      #   select(PK_ID:`10`) -> poh_data
      temp = bind_rows(
        mhs_poh_tbl %>%
          select(PK_ID:`10`) %>%
          inner_join(
            contract_res(),
            by = c('MATERIAL_NUM' = 'XREF PART NUMBER'),
            keep = T,
            copy = T
          ) %>%
          select(all_of(poh_col_order[[1]])) %>%
          collect() %>%
          select(all_of(poh_col_order[[2]])) %>%
          
          filter(CREATE_DATE >= start_date, CREATE_DATE <= end_date)
        ,
        mhs_poh_tbl %>%
          select(PK_ID:`10`) %>%
          inner_join(
            contract_res(),
            by = c('VENDOR_MATERIAL_NUM' = 'XREF PART NUMBER'),
            keep = T,
            copy = T
          ) %>%
          select(all_of(poh_col_order[[1]])) %>%
          collect() %>%
          select(all_of(poh_col_order[[2]])) %>%
      
          filter(CREATE_DATE >= start_date, CREATE_DATE <= end_date),
        mhs_poh_tbl %>%
          select(PK_ID:`10`) %>%
          inner_join(
            contract_res(),
            by = c('MANUFACTURER_PART_NUM' = 'XREF PART NUMBER'),
            keep = T,
            copy = T
          ) %>%
          select(all_of(poh_col_order[[1]])) %>%
          collect() %>%
          select(all_of(poh_col_order[[2]])) %>%
          
          filter(CREATE_DATE >= start_date, CREATE_DATE <= end_date),
        mhs_poh_tbl %>%
          select(PK_ID:`10`) %>%
          inner_join(
            contract_res(),
            by = c('PREMIER_MANUFACTURER_CATALOG_NUMBER' = 'XREF PART NUMBER'),
            keep = T,
            copy = T
          ) %>%
          select(all_of(poh_col_order[[1]])) %>%
          collect() %>%
          select(all_of(poh_col_order[[2]])) %>%

          filter(CREATE_DATE >= start_date, CREATE_DATE <= end_date)
      ) %>% 
      group_by(PK_ID) %>%
        filter(row_number() == 1) %>%
        ungroup() %>%
        filter(PO_SPEND != 0)
      
      
    })
    
    output$location_selector <- renderUI({
      req(po_raw())
      selectizeInput(
        'facility_filter',
        'Select Facilitys: ',
        choices = unique(po_raw()$COMPANY_ID),
        multiple = T
      )
    })
    
    
    po_location_filter = eventReactive(input$refine_data, {
      req(po_raw(), input$facility_filter)
      po_raw()[po_raw()$COMPANY_ID %in% input$facility_filter, ]
    })
    
    
    
    
    output$raw_po <- renderDataTable({
      po_location_filter()
    })
    output$downloadData <- downloadHandler(
      filename = function() {
        paste('FIA_Raw_', Sys.time(), '.csv', sep = '')
      },
      content = function(file) {
        write_csv(po_location_filter(), file)
      }
    )
    item_level_raw <- eventReactive(input$refine_data, {
      req(po_location_filter())
      
      filtered_data <- po_location_filter() %>%
        group_by(
          VENDOR_NAME,
          VENDOR_MATERIAL_NUM,
          PO_UOM,
          NET_PRICE,
          `XREF PART NUMBER`,
          `XREF ITEM DESCRIPTION`,
          `UOM`,
          `C Rate MFG`,
          `Proposed Price`
        ) %>%
        summarise(PO_QUANTITY = sum(PO_QUANTITY, na.rm = TRUE),
                  .groups = "drop") %>%
        left_join(
          po_location_filter() %>%
            group_by(VENDOR_NAME, VENDOR_MATERIAL_NUM, PO_UOM) %>%
            arrange(desc(CREATE_DATE)) %>%
            filter(row_number() == 1) %>%
            select(
              VENDOR_NAME,
              VENDOR_MATERIAL_NUM,
              PO_UOM,
              ITEM_DESCRIPTION
            ) %>%
            rename(`Most Recent Description` = ITEM_DESCRIPTION),
          by = c("VENDOR_NAME", "VENDOR_MATERIAL_NUM", "PO_UOM")
        ) %>%
        mutate(
          Conversion_Factor = `C Rate MFG`,
          EA_Usage = Conversion_Factor * PO_QUANTITY,
          `Proposed Price` = as.numeric(gsub("[^0-9.]", "", `Proposed Price`)),
          `Proposed Price` = ifelse(is.na(`Proposed Price`), 0, `Proposed Price`),
          Included = "Yes",
          Impact = 0,
          Impact_Percent = 0
        )
      
      filtered_data
    })
    
    reactive_data <- reactiveVal()
    
    observeEvent(item_level_raw(), {
      reactive_data(item_level_raw())
    })
    
    output$data_table <- renderDT({
      datatable(
        reactive_data(),
        editable = list(target = "cell", disable = list(columns = which(
          !colnames(reactive_data()) %in% c("Conversion_Factor", "Included")
        ))),
        selection = "none"
      )
    })
    
    observeEvent(input$data_table_cell_edit, {
      info <- input$data_table_cell_edit
      data <- reactive_data()
      
      if (colnames(data)[info$col] == "Conversion_Factor") {
        data[info$row, "Conversion_Factor"] <- as.numeric(info$value)
      } else if (colnames(data)[info$col] == "Included") {
        data[info$row, "Included"] <- info$value
      }
      
      reactive_data(data)
    })
    
    observeEvent(input$finalize, {
      finalized_data <- reactive_data()
      write.csv(finalized_data, "finalized_report.csv", row.names = FALSE)
      
      showModal(
        modalDialog(
          title = "Finalized Report",
          "The report has been finalized and saved for download.",
          easyClose = TRUE
        )
      )
    })
    
    
    
    
  }
)
