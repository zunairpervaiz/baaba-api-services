# Table of Contents

- [Installation](#installation)
- [Features](#features)
  - [Network APIs Handler](#1-network-apis-handler)
  - [API Cache Management](#2-api-cache-management)

## Installation

Follow these steps to install and integrate API Services into your Flutter project:

#### 1. Add Dependency

Add it to your `pubspec.yaml` file under the `dependencies` section:

```yaml
dependencies:
  baaba_api_handler: ^1.0.2
```

| Property | Type   | Description                                         |
| -------- | ------ | --------------------------------------------------- |
| url      | String | URL of the Git repository.                          |
| ref      | String | Branch reference to be fetched from the repository. |
| path     | String | Path of the required package.                       |

#### 2. Install Packages

Run the following command in your terminal to install the dependencies:

```bash
flutter pub get
```

#### 3. Import the library

Import in your Dart code:

```dart
import 'package:baaba_api_handler/ts_api_handler.dart';
```

## Features

### 1. Network APIs Handler

Baaba API Handler provides network API handling utilities to simplify communication with external APIs and services. With Baaba API handling methods, you can easily make HTTP requests, handle responses, and manage network interactions in your flutter project.

Once imported, create an object of ApiServices and ApiCacheHelper into your dart code to access its features and functionalities:

```dart
ApiServices apiServices =  ApiServices.intance();
```

Each method within the API handler contains the following properties for configuration:

| Property       | Type                | Required | Description                                                                                                  | Example                                  |
| -------------- | ------------------- | -------- | ------------------------------------------------------------------------------------------------------------ | ---------------------------------------- |
| endpoint       | String              | Yes      | The URL of the endpoint where the API request will be sent.                                                  | https://example.com                      |
| data           | Object              | No       | The data object to be sent with the request.                                                                 | `{ "name": "Baaba Devs" }`            |
| headers        | Object              | No       | The headers to be included in the request.                                                                   | `{ "content-type": "application/json" }` |
| params         | Map<String,dynamic> | No       | The parameters to be included in the request.                                                                | `{ "code": 123 }`                        |
| receiveTimeout | Duration            | No       | The timeout duration for receiving a response from the server which can be in seconds, minutes or hours etc. | Duration(seconds:30)                     |
| sendTimeout    | Duration            | No       | The timeout duration for sending the request to the server which can be in seconds, minutes or hours etc.    | Duration(seconds:30)                     |

#### 4.1 GET

You can use the following example to make GET request.

```dart
// Make a GET request
Either<Failure, Response<dynamic>> response =  await apiServices.get(endpoint: endpoint);
```

#### 4.2 POST

You can use the following example to make POST request.

```dart
// Make a POST request
Either<Failure, Response<dynamic>> response =  await apiServices.post(endpoint: endpoint)
```

#### 4.3 PUT

You can use the following example to make PUT request.

```dart
// Make a PUT request
Either<Failure, Response<dynamic>> response =  await apiServices.put(endpoint: endpoint);
```

#### 4.4 PATCH

You can use the following example to make PATCH request.

```dart
// Make a PATCH request
Either<Failure, Response<dynamic>> response =  await apiServices.patch(endpoint: endpoint);
```

#### 4.5 DELETE

You can use the following example to make DELETE request.

```dart
// Make a DELETE request
Either<Failure, Response<dynamic>> response =  await apiServices.delete(endpoint: endpoint);
```

`GET`, `POST`, `PATCH`, `PUT` and `DELETE` methods returns the response as `Either<Failure, Response<dynamic>>` which you can handle as demonstrated below:

```dart
// Handle the response
response.fold(
  (failure) =>  print(failure.toString()),  // Log the failure
  (success) =>  print(success.data),  // Log the response data
);
```

| Property | Type     | Description                                                                                                            |     |
| -------- | -------- | ---------------------------------------------------------------------------------------------------------------------- | --- |
| failure  | Failure  | Represents a failure response from an HTTP request, encapsulating error details such as status code and error message. |
| success  | Response | Represents a successful response from an HTTP request, containing the data and metadata returned by the server.        |

#### 4.6 CANCEL

You can cancel the most recent API request by using the following method:

```dart
apiServices.cancelRequest();
```

| Property           | Type   | Required | Description                                                                            |
| ------------------ | ------ | -------- | -------------------------------------------------------------------------------------- |
| cancellationReason | String | No       | This field is typically used to provide context or details for the cancellation event. |

### 2. API Cache Management

Baaba API Handler provides the functionality of caching the API response into local database for reducing unnecessary API calls and making the app offline first. To access these functionalities in your flutter app:

```dart
ApiCacheHelper apiCacheHelper = ApiCacheHelper.instance;
```

All the methods provided for caching of response are as follows:

#### 5.1 GET

This method gets the cached api response into the local database with the provided url.

```dart
APICacheDBModel? response =  await apiCacheHelper.getCacheData(url);
```

| Property | Type   | Required | Description                                            |
| -------- | ------ | -------- | ------------------------------------------------------ |
| url      | String | Yes      | The URL of the HTTP request stored in to the database. |

#### 5.2 SET

This method sets the api response into the local database with the provided url and data.

```dart
bool isStored =  await apiCacheHelper.setCacheData(url, data);
```

| Property | Type   | Required | Description                                             |
| -------- | ------ | -------- | ------------------------------------------------------- |
| url      | String | Yes      | The URL of the HTTP request to be stored into database. |
| data     | String | Yes      | The data to be cached e.g API response.                 |

#### 5.3 CLEAR

This method removes the api response from the local database for the provided url.

```dart
bool isCleared =  await apiCacheHelper.clearCache(url);
```

| Property | Type   | Required | Description                                             |
| -------- | ------ | -------- | ------------------------------------------------------- |
| url      | String | Yes      | The URL of the HTTP request to clear from the database. |

#### 5.4 EXISTS

This method checks if the cached response for the provided url is available in the local database.

```dart
bool exists =  await apiCacheHelper.isCacheExist(url);
```

| Property | Type   | Required | Description                                           |
| -------- | ------ | -------- | ----------------------------------------------------- |
| url      | String | Yes      | The URL of the HTTP request stored into the database. |

#### 5.5 CLEAR ALL

This method removes all the cached api response from the local database.

```dart
await apiCacheHelper.clearAllCache();
```
