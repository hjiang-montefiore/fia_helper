library(shiny)
library(openxlsx)
library(DT)
library(tidyverse)
library(DBI)
library(readxl)
library(yaml)
library(shinyWidgets)
library(shinyjs)


downloadButton <- function(...) {
  tag <- shiny::downloadButton(...)
  tag$attribs$download <- NULL
  tag
}


find_start_end_date <- function(date = NULL) {
  if (is.null(date)) {
    previous_date = Sys.Date()
  } else{
    previous_date <- as.Date(date)
  }
  
  # Extract the year and month from the previous date
  year <- format(previous_date, "%Y")
  month <- format(previous_date, "%m")
  
  # Create a new date object with the extracted year and month
  latest_last_month_date <- as.Date(paste(year, month, "01", sep = "-"))
  
  # Find the last day of the previous month
  last_day <- as.Date(format(latest_last_month_date, "%Y-%m-%d")) - 1
  
  new_month = as.integer(month) - 12
  new_year = as.integer(year)
  
  
  if (new_month <= 0) {
    new_month <- new_month + 12
    new_year <- new_year - 1
  }
  
  start_day = as.Date(paste(new_year, new_month, '01', sep = '-'))
  
  
  return(list(start_day, last_day))
}

default_dates = find_start_end_date()

config <- yaml::read_yaml('config.yml')
con_string = paste0(
  "DSN=SQLServerMIT;UID=DM_MONTYNT\\",
  config$database$user,
  ";",
  "PWD=",
  config$database$pwd
)

con <- dbConnect(odbc::odbc(), .connection_string = con_string)



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

poh_col_order[[1]][poh_col_order[[1]] == 'PROPOSED_PRICE'] = 'Proposed Price'
poh_col_order[[1]][poh_col_order[[1]] == 'C_RATE_MFG'] = 'C Rate MFG'
poh_col_order[[1]][poh_col_order[[1]] == 'XREF_ITEM_DESCRIPTION'] = 'XREF ITEM DESCRIPTION'
poh_col_order[[1]][poh_col_order[[1]] == 'XREF_PART_NUMBER'] = 'XREF PART NUMBER'


poh_col_order[[2]][poh_col_order[[2]] == 'PROPOSED_PRICE'] = 'Proposed Price'
poh_col_order[[2]][poh_col_order[[2]] == 'C_RATE_MFG'] = 'C Rate MFG'
poh_col_order[[2]][poh_col_order[[2]] == 'XREF_ITEM_DESCRIPTION'] = 'XREF ITEM DESCRIPTION'
poh_col_order[[2]][poh_col_order[[2]] == 'XREF_PART_NUMBER'] = 'XREF PART NUMBER'




poh_col_order[[1]] = poh_col_order[[1]][-136]
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
          dateRangeInput(
            inputId = 'date',
            label = 'Date Range',
            start = default_dates[[1]],
            end = default_dates[[2]]
          ),
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
    
    # observeEvent(raw_contract(), {
    #   choices <- colnames(raw_contract())
    #   updateSelectInput(inputId = 'catalog_col', choices = choices)
    # })
    # observeEvent(raw_contract(), {
    #   choices <- colnames(raw_contract())
    #   updateSelectInput(inputId = 'price_col', choices = choices)
    # })
    # observeEvent(raw_contract(), {
    #   choices <- colnames(raw_contract())
    #   updateSelectInput(inputId = 'c_rate_col', choices = choices)
    # })
    # observeEvent(raw_contract(), {
    #   choices <- colnames(raw_contract())
    #   updateSelectInput(inputId = 'uom_col', choices = choices)
    # })
    # observeEvent(raw_contract(), {
    #   choices <- colnames(raw_contract())
    #   updateSelectInput(inputId = 'description_col', choices = choices)
    # })
    
    
    # Define the input IDs for all column selection inputs
    input_ids <- c(
      'catalog_col', 
      'price_col', 
      'c_rate_col', 
      'uom_col', 
      'description_col'
    )
    
    # Update all select inputs when raw_contract() changes
    lapply(input_ids, function(id) {
      observeEvent(raw_contract(), {
        choices <- colnames(raw_contract())
        updateSelectInput(inputId = id, choices = choices)
      })
    })
    
    # Check for overlapping selections across all inputs
    observe({
      # Get current selections from all inputs
      selections <- lapply(input_ids, function(id) input[[id]] %||% "")
      selections <- unlist(selections)
      
      # Remove empty selections
      non_empty <- selections[selections != ""]
      
      # Check for duplicates only if there are selections
      if (length(non_empty) > 0) {
        duplicates <- unique(non_empty[duplicated(non_empty)])
        
        # Show warning if duplicates found
        if (length(duplicates) > 0) {
          warning_msg <- paste(
            "Warning: The following columns are selected in multiple fields:",
            paste(duplicates, collapse = ", ")
          )
          showNotification(warning_msg, type = "warning")
        }
      }
    }) %>% bindEvent(lapply(input_ids, function(id) input[[id]]))
    
    
    # Progress_bar_Start ------------------------------------------------------
    
    contract_res <- eventReactive(input$action_final, {
      withProgress(message = 'Data Collection in progress',
                   detail = 'This may take a while...',
                   value = 0,
                   # Initial progress value
                   {
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
                     
                     # Step 1: Initial transformation (update progress to 30%)
                     incProgress(0.3, detail = "Transforming raw contract data...")
                     Sys.sleep(0.5) # Simulated delay for visibility of the progress bar
                     
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
                              `XREF PART NUMBER`) %>%
                       mutate(`XREF PART NUMBER` = as.character(`XREF PART NUMBER`))
                     
                     # Step 2: Apply transformations based on input choices (update progress to 60%)
                     incProgress(0.3, detail = "Applying transformations...")
                     Sys.sleep(0.5) # Simulated delay for visibility of the progress bar
                     
                     temp <- if (input$tick_choice == "Yes") {
                       if (input$character_choice == "Yes") {
                         bind_rows(
                           temp %>%
                             mutate(`XREF PART NUMBER` = substr(
                               `XREF PART NUMBER`, 2, nchar(`XREF PART NUMBER`)
                             )),
                           temp %>%
                             mutate(
                               `XREF PART NUMBER` = `XREF PART NUMBER` %>%
                                 substr(2, nchar(.)) %>%
                                 gsub("[^[:alnum:]]", "", .)
                             )
                         ) %>% unique()
                       } else {
                         temp %>%
                           mutate(`XREF PART NUMBER` = substr(`XREF PART NUMBER`, 2, nchar(`XREF PART NUMBER`)))
                       }
                     } else {
                       if (input$character_choice == "Yes") {
                         bind_rows(temp, temp %>%
                                     mutate(
                                       `XREF PART NUMBER` = gsub("[^[:alnum:]]", "", `XREF PART NUMBER`)
                                     )) %>% unique()
                       } else {
                         temp
                       }
                     }
                     
                     # Step 3: Finalize and return the result (update progress to 100%)
                     incProgress(0.4, detail = "Finalizing and returning results...")
                     Sys.sleep(0.5) # Simulated delay for visibility of the progress bar
                     
                     temp
                   })
    })
    
    
    
    # Progress_bar_end --------------------------------------------------------
    
    
    
    output$raw_contract <- renderDataTable({
      raw_contract()
    })
    output$clean_contract <- renderDataTable({
      contract_res()
    })
    
    
    
    po_raw <- eventReactive(input$action_po_collect, {
      withProgress(message = "Processing PO Data",
                   detail = "This may take a while...",
                   value = 0,
                   # Initial progress value
                   {
                     req(input$date)
                     start_date <- isolate(as.character(input$date[[1]]))
                     end_date <- isolate(as.character(input$date[[2]]))
                     
                     # Step 1: Initialize progress (update progress to 10%)
                     incProgress(0.1, detail = "Preparing data...")
                     Sys.sleep(0.5) # Simulated delay for better visibility
                     
                     # Step 2: Perform the main data binding and filtering (update progress incrementally)
                     temp <- bind_rows({
                       incProgress(0.2, detail = "Processing MATERIAL_NUM...")
                       Sys.sleep(0.5) # Simulated delay
                       mhs_poh_tbl %>%
                         select(PK_ID:`10`) %>%
                         inner_join(
                           contract_res(),
                           by = c('MATERIAL_NUM' = 'XREF PART NUMBER'),
                           keep = TRUE,
                           copy = TRUE
                         ) %>%
                         select(all_of(poh_col_order[[1]])) %>%
                         collect() %>%
                         select(all_of(poh_col_order[[2]])) %>%
                         filter(CREATE_DATE >= start_date, CREATE_DATE <= end_date)
                     }, {
                       incProgress(0.2, detail = "Processing VENDOR_MATERIAL_NUM...")
                       Sys.sleep(0.5) # Simulated delay
                       mhs_poh_tbl %>%
                         select(PK_ID:`10`) %>%
                         inner_join(
                           contract_res(),
                           by = c('VENDOR_MATERIAL_NUM' = 'XREF PART NUMBER'),
                           keep = TRUE,
                           copy = TRUE
                         ) %>%
                         select(all_of(poh_col_order[[1]])) %>%
                         collect() %>%
                         select(all_of(poh_col_order[[2]])) %>%
                         filter(CREATE_DATE >= start_date, CREATE_DATE <= end_date)
                     }, {
                       incProgress(0.2, detail = "Processing MANUFACTURER_PART_NUM...")
                       Sys.sleep(0.5) # Simulated delay
                       mhs_poh_tbl %>%
                         select(PK_ID:`10`) %>%
                         inner_join(
                           contract_res(),
                           by = c('MANUFACTURER_PART_NUM' = 'XREF PART NUMBER'),
                           keep = TRUE,
                           copy = TRUE
                         ) %>%
                         select(all_of(poh_col_order[[1]])) %>%
                         collect() %>%
                         select(all_of(poh_col_order[[2]])) %>%
                         filter(CREATE_DATE >= start_date, CREATE_DATE <= end_date)
                     }, {
                       incProgress(0.2, detail = "Processing PREMIER_MANUFACTURER_CATALOG_NUMBER...")
                       Sys.sleep(0.5) # Simulated delay
                       mhs_poh_tbl %>%
                         select(PK_ID:`10`) %>%
                         inner_join(
                           contract_res(),
                           by = c('PREMIER_MANUFACTURER_CATALOG_NUMBER' = 'XREF PART NUMBER'),
                           keep = TRUE,
                           copy = TRUE
                         ) %>%
                         select(all_of(poh_col_order[[1]])) %>%
                         collect() %>%
                         select(all_of(poh_col_order[[2]])) %>%
                         filter(CREATE_DATE >= start_date, CREATE_DATE <= end_date)
                     }) %>%
                       group_by(PK_ID) %>%
                       filter(row_number() == 1) %>%
                       ungroup() %>%
                       filter(PO_SPEND != 0)
                     
                     # Step 3: Finalizing data (update progress to 100%)
                     incProgress(0.3, detail = "Finalizing and cleaning data...")
                     Sys.sleep(0.5) # Simulated delay for better visibility
                     
                     temp
                   })
    })
    
    
    output$location_selector <- renderUI({
      req(po_raw())
      pickerInput(
        'facility_filter',
        'Select Facilities: ',
        choices = unique(po_raw()$COMPANY_ID),
        multiple = T,
        options = list(`actions-box` = T)
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
        write_csv(po_location_filter(), file, na = '')
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
          Conversion_Factor = as.numeric(gsub("[^0-9.]", "", `C Rate MFG`)),
          Conversion_Factor = if_else(is.na(Conversion_Factor), 0, Conversion_Factor),
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
