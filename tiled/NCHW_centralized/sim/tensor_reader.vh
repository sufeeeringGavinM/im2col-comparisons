  // Read the generated whitespace-separated hex format, with // comments.
  // Reject missing, short, extra, malformed, or unknown words before using them
  // in either the reference calculation or the hardware preload.
  task read_tensor;
    input string path;
    input integer is_kernel;
    input integer d0, d1, d2, d3;
    integer handle, status, count, digit, h0, h1, h2, h3;
    string token;
    reg [8191:0] comment;
    reg [BIT_WIDTH-1:0] value;
    begin
      handle = $fopen(path, "r");
      if (!handle) $fatal(1, "Cannot open tensor file: %s", path);
      count = 0;
      while (!$feof(handle)) begin
        status = $fscanf(handle, "%s", token);
        if (status == 1) begin
          if (token.len() >= 2 && token.substr(0, 1) == "//") begin
            comment = 0;
            status = $fgets(comment, handle);
            if (token == "//" && $sscanf(comment, " shape=(%d, %d, %d, %d)", h0, h1, h2, h3) == 4)
              if (h0 != d0 || h1 != d1 || h2 != d2 || h3 != d3)
                $fatal(1, "Tensor shape does not match configuration: %s", path);
          end else begin
            if (count >= d0*d1*d2*d3)
              $fatal(1, "Extra tensor words: %s", path);
            if (token.len() > (BIT_WIDTH+3)/4)
              $fatal(1, "Tensor word exceeds operand width: %s", path);
            for (digit = 0; digit < token.len(); digit = digit + 1)
              if (!((token[digit] >= "0" && token[digit] <= "9") ||
                    (token[digit] >= "a" && token[digit] <= "f") ||
                    (token[digit] >= "A" && token[digit] <= "F")))
                $fatal(1, "Invalid or unknown tensor word '%s': %s", token, path);
            status = $sscanf(token, "%h", value);
            if (status != 1 || $isunknown(value))
              $fatal(1, "Invalid or unknown tensor word: %s", path);
            if (is_kernel) kernel_tensor[count] = value;
            else input_tensor[count] = value;
            count = count + 1;
          end
        end else if (!$feof(handle)) $fatal(1, "Cannot read tensor file: %s", path);
      end
      $fclose(handle);
      if (count != d0*d1*d2*d3)
        $fatal(1, "Short tensor file: %s; expected %0d words, read %0d", path, d0*d1*d2*d3, count);
    end
  endtask
