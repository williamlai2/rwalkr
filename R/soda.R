globalVariables(c(
  "Time", "Count", "Sensor", "Date", "Date_Time", # melb_walk_fast()
  "direction_1", "direction_2", "installation_date", "note", "sensor_description",
  "sensor_df", "sensor_id", "status", "latitude", "longitude",
  "date_time", "time", "total_of_directions"
))

#' API using Socrata to Melbourne pedestrian data (per hour)
#'
#' @param year An integer or a vector of integers. By default, it's the current
#' year.
#' @param sensor Sensor names. By default, it pulls all the sensors. Use [pull_sensor]
#' to see the available sensors.
#' @param na.rm Logical. `FALSE` is the default suggesting to include `NA` in
#' the dataset. `TRUE` removes the `NA`s.
#' @param app_token Characters giving the application token. A limited number of
#' requests can be made without an app token (`NULL`), but they are subject
#' to much lower throttling limits than request that do include one. Sign up
#' for an app token [here](https://data.melbourne.vic.gov.au/profile/app_tokens).
#'
#' @details It provides the API using [Socrata](https://dev.socrata.com/foundry/data.melbourne.vic.gov.au/mxb8-wn4w),
#' where counts are uploaded on a monthly basis. The up-to-date data would be
#' till the previous month. The data is sourced from
#' [Melbourne Open Data Portal](https://data.melbourne.vic.gov.au/Transport-Movement/Pedestrian-volume-updated-monthly-/b2ak-trbp).
#' Please refer to Melbourne Open Data Portal for more details about the dataset and
#' its policy.
#' @return A tibble including these variables as follows:
#' * `Sensor`: Sensor name
#' * `Date_Time`: Date time when the pedestrian counts are recorded
#' (at Australia/Melbourne)
#' * `Date`: Date associated with `Date_Time`
#' * `Time`: Time of day
#' * `Count`: Hourly counts
#'
#' @export
#' @seealso [melb_walk]
#'
#' @examples
#' \dontrun{
#' # Retrieve the year 2017
#' melb_walk_fast(year = 2017)
#'
#' # Retrieve the year 2017 for Southern Cross Station
#' melb_walk_fast(year = 2017, sensor = "Southern Cross Station")
#' }
melb_walk_fast <- function(year = NULL, sensor = NULL, na.rm = FALSE,
  app_token = NULL) {
  tz <- "Australia/Melbourne"
  this_year <- as.integer(format(Sys.Date(), "%Y"))
  if (is.null(year)) {
    year <- this_year
  }
  stopifnot(year > 2008 && year < (this_year + 1L))
  base_url <- "https://data.melbourne.vic.gov.au/resource/mxb8-wn4w.csv?"
  sel_cols <- paste(
    "SELECT sensor_name AS Sensor,",
    "date_time AS Date_Time,",
    "hourly_counts AS Count"
  )
  year_str <- paste(year, collapse = ", ")
  query <- paste0(sel_cols, " WHERE year in", "(", year_str, ")")
  nsensors <- 50L
  if (!is.null(sensor)) {
    sensor_str <- paste(
      vapply(sensor, function(x) paste0("'", x, "'"), character(1)),
      collapse = ", "
    )
    query <- paste0(query, "AND sensor_name in", "(", sensor_str, ")")
    nsensors[] <- length(sensor) # overwrite nsensors
  }
  query <- paste0(query, " ORDER BY :id LIMIT 50000")
  limit <- 50000L

  # roughly the number of pages going through
  npages <- ceiling((366L * 24L * nsensors * length(year)) / limit)

  p <- progress::progress_bar$new(total = npages,
    format = "downloading [:bar] :percent eta: :eta")
  lst_dat <- lapply(seq_len(npages), function(x) {
    offset <- sprintf("%i", limit * (x - 1))
    update_query <- paste0(query, " OFFSET ", offset)
    if (!is.null(app_token)) {
      app_token <- paste0("$$app_token=", app_token)
      base_url <- paste0(base_url, app_token)
    }
    response <- httr::GET(base_url, query = list("$query" = update_query))
    content <- httr::content(response, as = "text", type = "text/csv",
      encoding = "UTF-8")
    dat <- dplyr::as_tibble(utils::read.csv(
      textConnection(content),
      colClasses = rep("character", 3L),
      stringsAsFactors = FALSE,
      nrows = limit
    ))
    p$tick()
    dat
  })

  ped <- dplyr::bind_rows(lst_dat)
  ped <- dplyr::mutate(
    ped,
    Date_Time = as.POSIXct(strptime(date_time, format = "%Y-%m-%dT%H:%M:%S"),
      tz = tz),
    date_time = NULL,
  )
  from_time <- as.POSIXct(paste0(min(year, na.rm = TRUE), "-01-01 00:00"),
      tz = tz)
  max_year <- max(year, na.rm = TRUE)
  to_time <- if (max_year == this_year) {
    max(ped$Date_Time, na.rm = TRUE)
  } else {
    as.POSIXct(paste0(max_year, "-12-31 23:00"), tz = tz)
  }
  ped <- dplyr::distinct(ped) # remove duplicates
  ped <- dplyr::filter(ped, Date_Time >= from_time, Date_Time <= to_time)

  if (!na.rm) {
    # Make implicit missingness to explicit
    ped <- tidyr::complete(ped,
      Date_Time = seq.POSIXt(from = from_time, to = to_time, by = "hour"),
      Sensor
    )
    ped <- dplyr::mutate(
      ped,
      Date = as.Date.POSIXct(Date_Time, tz = tz),
      Count = as.integer(Count),
      Time = as.integer(substr(Date_Time, 12, 13))
    )
  } else {
    ped <- dplyr::mutate(
      ped,
      Date = as.Date.POSIXct(Date_Time, tz = tz),
      Count = as.integer(Count),
      Time = as.integer(Time),
    )
  }

  ped <- dplyr::select(ped, Sensor, Date_Time, Date, Time, Count)
  dplyr::arrange(ped, Date_Time)
}

#' API using Socrata to Melbourne pedestrian data with directions (per minute)
#'
#' @inheritParams melb_walk_fast
#'
#' @details It provides the API using [Socrata](https://dev.socrata.com/foundry/data.melbourne.vic.gov.au/d6mv-s43h),
#' to access minute by minute directional pedestrian counts for *the last hour*
#' from pedestrian sensor devices located across the city. The data is updated
#' every 15 minutes.
#'
#' Columns `sensor_id`, `direction_1`, and `direction_2` can be used to join
#' the data with the Sensor Locations dataset which details the location, status,
#' and directional readings of sensors, which can be obtained from [pull_sensor()].
#'
#' @return A tibble including these variables as follows:
#' * `sensor_id`: Sensor name
#' * `date_time`: Date time when the pedestrian counts are recorded
#' * `date`: Date associated with `date_time`
#' * `time`: Time of day
#' * `direction_1`: Direction 1 sensor reading (count of pedestrians)
#' * `direction_2`: Direction 2 sensor reading (count of pedestrians)
#' * `total_of_directions`: Total sensor reading i.e. direction 1+2 (count of pedestrians)
#'
#' @seealso [pull_sensor()]
#'
#' @examples
#' \dontrun{
#' melb_walk_directional()
#' }
#' @export
melb_walk_directional <- function(app_token = NULL) {
  tz <- "Australia/Melbourne"
  base_url <- "https://data.melbourne.vic.gov.au/resource/d6mv-s43h.csv"
  sel_cols <- paste(
    "SELECT sensor_id", "date_time", "date", "time", "direction_1",
    "direction_2", "total_of_directions", sep = ", "
  )

  query <- paste0(sel_cols, " ORDER BY :id LIMIT 10000")
  if (!is.null(app_token)) {
    app_token <- paste0("$$app_token=", app_token)
    base_url <- paste0(base_url, app_token)
  }
  response <- httr::GET(base_url, query = list("$query" = query))
  content <- httr::content(response, as = "text", type = "text/csv",
    encoding = "UTF-8")
  ped <- dplyr::as_tibble(utils::read.csv(
    textConnection(content),
    colClasses = rep("character", 7L),
    stringsAsFactors = FALSE,
    nrows = 10000
  ))
  dplyr::mutate(
    ped,
    date_time = as.POSIXct(strptime(date_time, format = "%Y-%m-%dT%H:%M:%S"),
      tz = tz),
    date = as.Date.POSIXct(date_time, tz = tz),
    time = hms::parse_hm(time),
    direction_1 = as.integer(direction_1),
    direction_2 = as.integer(direction_2),
    total_of_directions = as.integer(total_of_directions)
  )
}

#' API using Socrata to Melbourne pedestrian sensor locations
#'
#' Provides API using Socrata to Melbourne pedestrian sensor locations.
#'
#' @inheritParams melb_walk_fast
#'
#' @details It provides API using [Socrata](https://data.melbourne.vic.gov.au/resource/h57g-5234).
#'
#' @export
#' @seealso [melb_walk_fast]
#'
#' @examples
#' \dontrun{
#' pull_sensor()
#' }
pull_sensor <- function(app_token = NULL) {
  base_url <- "https://data.melbourne.vic.gov.au/resource/h57g-5234.csv"
  p_url <- httr::parse_url(base_url)
  if (!is.null(app_token)) p_url$query$`$$app_token` <- app_token
  response <- httr::GET(p_url)
  content <- httr::content(response, as = "text", type = "text/csv",
    encoding = "UTF-8")
  sensor_info <- utils::read.csv(
    textConnection(content),
    colClasses = rep("character", 11L),
    stringsAsFactors = FALSE,
    na.strings = "",
    nrows = 100L
  )
  sensor_info <- dplyr::select(
    sensor_info, sensor = sensor_description, sensor_id, longitude, latitude, direction_1, direction_2, installation_date, status, note
  )
  sensor_info <- dplyr::mutate(
    sensor_info,
    longitude = as.numeric(longitude),
    latitude = as.numeric(latitude),
    installation_date = as.POSIXct(
      strptime(installation_date, format = "%Y-%m-%dT%H:%M:%S"),
      tz = "Australia/Melbourne")
  )
  dplyr::as_tibble(sensor_info)
}
