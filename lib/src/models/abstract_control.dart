// Copyright 2020 Joan Pablo Jiménez Milian. All rights reserved.
// Use of this source code is governed by the MIT license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:reactive_forms/reactive_forms.dart';

/// This is the base class for [FormGroup], [FormArray] and [FormControl].
///
/// It provides some of the shared behavior that all controls and groups have,
/// like running validators, calculating status, and resetting state.
///
/// It also defines the properties that are shared between all sub-classes,
/// like value and valid.
///
/// It shouldn't be instantiated directly.
abstract class AbstractControl<T> {
  ValueNotifier<ControlStatus> _onStatusChanged;
  final _onValueChanged = ValueNotifier<T>(null);
  final _onTouched = ValueNotifier<bool>(false);
  final List<ValidatorFunction> _validators;
  final List<AsyncValidatorFunction> _asyncValidators;
  final Map<String, dynamic> _errors = {};

  /// Async validators debounce timer.
  Timer _debounceTimer;

  /// Async validators debounce time in milliseconds.
  final int _asyncValidatorsDebounceTime;

  /// Gets if the control is touched or not.
  ///
  /// A control is touched when the user taps on the ReactiveFormField widget
  /// and then remove focus or completes the text edition. Validation messages
  /// will begin to show up when the FormControl is touched.
  bool get touched => _onTouched.value;

  /// Marks the control as touched.
  void touch() {
    this._onTouched.value = true;
  }

  /// Marks the control as untouched.
  void untouch() {
    this._onTouched.value = false;
  }

  ControlStatus _defaultStatus;

  /// Constructor of the [AbstractControl].
  AbstractControl({
    List<ValidatorFunction> validators,
    List<AsyncValidatorFunction> asyncValidators,
    bool touched = false,
    int asyncValidatorsDebounceTime = 250,
    bool disabled = false,
  })  : assert(asyncValidatorsDebounceTime >= 0),
        _validators = validators ?? const [],
        _asyncValidators = asyncValidators ?? const [],
        _asyncValidatorsDebounceTime = asyncValidatorsDebounceTime {
    _defaultStatus = disabled ? ControlStatus.disabled : ControlStatus.valid;
    _onStatusChanged = ValueNotifier<ControlStatus>(_defaultStatus);
    _onTouched.value = touched;
  }

  /// The list of functions that determines the validity of this control.
  ///
  /// In [FormGroup] these come in handy when you want to perform validation
  /// that considers the value of more than one child control.
  List<ValidatorFunction> get validators => List.unmodifiable(_validators);

  /// The list of async functions that determines the validity of this control.
  ///
  /// In [FormGroup] these come in handy when you want to perform validation
  /// that considers the value of more than one child control.
  List<AsyncValidatorFunction> get asyncValidators =>
      List.unmodifiable(_asyncValidators);

  /// The current value of the control.
  T get value;

  /// Sets the value to the control
  set value(T newValue);

  /// An object containing any errors generated by failing validation,
  /// or empty [Map] if there are no errors.
  Map<String, dynamic> get errors => Map.unmodifiable(_errors);

  /// A [ValueListenable] that emits an event every time the validation status
  /// of the control changes.
  ValueListenable<ControlStatus> get onStatusChanged => _onStatusChanged;

  /// A [ValueListenable] that emits an event every time the value
  /// of the control changes.
  ValueListenable<T> get onValueChanged => _onValueChanged;

  /// A [ValueListenable] that emits an event every time the control
  /// is touched or untouched.
  ValueListenable<bool> get onTouched => _onTouched;

  /// A control is valid when its [status] is ControlStatus.valid.
  bool get valid => this.status == ControlStatus.valid;

  /// A control is invalid when its [status] is ControlStatus.invalid.
  bool get invalid => this.status == ControlStatus.invalid;

  /// A control is pending when its [status] is ControlStatus.pending.
  bool get pending => this.status == ControlStatus.pending;

  bool get disabled => this.status == ControlStatus.disabled;

  bool get enabled => !this.disabled;

  /// True whether the control has validation errors.
  bool get hasErrors => this._errors.keys.length > 0;

  /// The validation status of the control.
  ///
  /// There are four possible validation status values:
  /// * VALID: This control has passed all validation checks.
  /// * INVALID: This control has failed at least one validation check.
  /// * PENDING: This control is in the midst of conducting a validation check.
  ///
  /// These status values are mutually exclusive, so a control cannot be both
  /// valid AND invalid or invalid AND pending.
  ControlStatus get status => _onStatusChanged.value;

  void enable() {
    if (this.enabled) {
      return;
    }
    this.notifyStatusChanged(ControlStatus.pending);
    this.validate();
  }

  void disable() {
    this._errors.clear();
    this.notifyStatusChanged(ControlStatus.disabled);
  }

  /// Disposes the control
  @protected
  void dispose() {
    _onStatusChanged.dispose();
    _onValueChanged.dispose();
    _runningAsyncValidators?.cancel();
  }

  /// Resets the control.
  void reset();

  @protected
  void notifyValueChanged(T value) {
    _onValueChanged.value = value;
  }

  @visibleForTesting
  @protected
  void notifyStatusChanged(ControlStatus status) {
    _onStatusChanged.value = status;
  }

  /// Add errors when running validations manually, rather than automatically.
  ///
  /// ### Example:
  ///
  /// ```dart
  /// final passwordConfirmation = FormControl();
  ///
  /// passwordConfirmation.addError({'mustMatch': true});
  ///```
  ///
  /// See also [AbstractControl.removeError]
  void addError(Map<String, dynamic> error) {
    this._errors.addAll(error);
    checkValidityAndUpdateStatus();
  }

  /// Remove errors by name.
  ///
  /// ### Example:
  ///
  ///```dart
  /// final passwordConfirmation = FormControl();
  ///
  /// passwordConfirmation.removeError('mustMatch');
  ///```
  ///
  /// See also [AbstractControl.addError]
  void removeError(String errorName) {
    this._errors.remove(errorName);
    checkValidityAndUpdateStatus();
  }

  /// Sets errors on a form control when running validations manually,
  /// rather than automatically.
  void setErrors(Map<String, dynamic> errors) {
    this._errors.clear();
    this._errors.addAll(errors);
    checkValidityAndUpdateStatus();
  }

  /// This method is for internal use
  @protected
  void checkValidityAndUpdateStatus() {
    final status = this.hasErrors ? ControlStatus.invalid : ControlStatus.valid;
    notifyStatusChanged(status);
  }

  /// Validates the current control.
  @protected
  void validate() {
    if (this.disabled) {
      return;
    }

    this.notifyStatusChanged(ControlStatus.pending);

    _errors.clear();
    this.validators.forEach((validator) {
      final error = validator(this);
      if (error != null) {
        _errors.addAll(error);
      }
    });

    if (_errors.keys.isNotEmpty || this.asyncValidators.isEmpty) {
      checkValidityAndUpdateStatus();
    } else {
      if (_debounceTimer != null) {
        _debounceTimer.cancel();
      }

      _debounceTimer =
          Timer(Duration(milliseconds: _asyncValidatorsDebounceTime), () {
        validateAsync();
      });
    }
  }

  StreamSubscription _runningAsyncValidators;

  /// runs async validators to validate the value of current control
  @protected
  Future<void> validateAsync() async {
    if (_runningAsyncValidators != null) {
      await _runningAsyncValidators.cancel();
      _runningAsyncValidators = null;
    }

    final validatorsStream = Stream.fromFutures(
        this.asyncValidators.map((validator) => validator(this)));

    final errors = Map<String, dynamic>();
    _runningAsyncValidators = validatorsStream.listen(
      (error) {
        if (error != null) {
          errors.addAll(error);
        }
      },
      onDone: () {
        _errors.addAll(errors);
        if (this.pending) {
          checkValidityAndUpdateStatus();
        }
      },
    );
  }
}
