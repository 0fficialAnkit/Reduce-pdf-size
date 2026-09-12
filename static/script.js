// document.getElementById('uploadForm').addEventListener('submit', function(e) {
//   e.preventDefault();

//   const fileInput = document.getElementById('pdfInput');
//   const resultDiv = document.getElementById('result');
//   const file = fileInput.files[0];

//   if (!file) {
//     resultDiv.innerHTML = '<p>Please select a PDF file.</p>';
//     return;
//   }

//   const formData = new FormData();
//   formData.append('pdf', file);

//   fetch('/compress', {
//     method: 'POST',
//     body: formData
//   })
//   .then(response => response.json())
//   .then(data => {
//     if (data.download_url) {
//       resultDiv.innerHTML = `<p><a href="${data.download_url}" download>Download Compressed PDF</a></p>`;
//     } else {
//       resultDiv.innerHTML = '<p>Compression failed. Try again.</p>';
//     }
//   })
//   .catch(err => {
//     console.error(err);
//     resultDiv.innerHTML = '<p>Error uploading file.</p>';
//   });
// });


























document.getElementById('uploadForm').addEventListener('submit', function(e) {
  e.preventDefault();

  const fileInput = document.getElementById('pdfInput');
  const resultDiv = document.getElementById('result');
  const file = fileInput.files[0];

  if (!file) {
    resultDiv.innerHTML = '<p>Please select a PDF file.</p>';
    return;
  }

  const formData = new FormData();
  formData.append('pdf', file);

  resultDiv.innerHTML = '<p>Compressing PDF, please wait...</p>';

  fetch('/compress', {
    method: 'POST',
    body: formData
  })
  .then(response => response.json())
  .then(data => {
    if (data.download_url) {
      resultDiv.innerHTML = `<p><a href="${data.download_url}" download>📥 Download Compressed PDF</a></p>`;
    } else {
      resultDiv.innerHTML = '<p>Compression failed. Please try again.</p>';
    }
  })
  .catch(err => {
    console.error(err);
    resultDiv.innerHTML = '<p>Error uploading or compressing file.</p>';
  });
});
